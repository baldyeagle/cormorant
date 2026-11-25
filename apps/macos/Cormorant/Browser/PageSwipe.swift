import AppKit
import WebKit

/// Pictures of a tab's recent pages, by back/forward item, for the back/forward swipe to show the page
/// it's going to. WebKit's own swipe pictures came out blank on macOS 26; `takeSnapshot` doesn't.
final class BackForwardPictures {
    private weak var webView: WKWebView?
    /// Newest last.
    private var pictures: [(item: WeakItem, image: NSImage)] = []
    private var pending: Task<Void, Never>?

    /// Each is the size of the page at the screen's scale, so a tab keeps only a few.
    private static let kept = 6

    private struct WeakItem {
        weak var item: WKBackForwardListItem?
    }

    init(webView: WKWebView) {
        self.webView = webView
    }

    func picture(for item: WKBackForwardListItem?) -> NSImage? {
        guard let item else { return nil }
        return pictures.last { $0.item.item === item }?.image
    }

    /// Pictures the page on screen for its back/forward item, after `delay` (for a page to settle);
    /// a later call replaces one still waiting.
    func takePicture(after delay: Duration = .zero) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let webView, webView.window != nil,
                  let item = webView.backForwardList.currentItem,
                  let image = try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration()),
                  webView.backForwardList.currentItem === item else { return }
            pictures.removeAll { $0.item.item == nil || $0.item.item === item }
            pictures.append((WeakItem(item: item), image))
            if pictures.count > Self.kept { pictures.removeFirst(pictures.count - Self.kept) }
        }
    }

    /// For a tab out of sight: only the pages a swipe would go to from where it is.
    func keepNeighboursOnly() {
        pending?.cancel()
        let list = webView?.backForwardList
        pictures.removeAll { entry in
            guard let item = entry.item.item else { return true }
            return item !== list?.backItem && item !== list?.forwardItem
        }
    }
}

/// What the page tells the back/forward swipe: whether it used a sideways scroll itself (a map, a
/// carousel, a wide table), so the swipe leaves it alone, and when a page it went to first drew. Runs in
/// its own script world, out of the page's reach.
final class PageSwipeScript: NSObject, WKScriptMessageHandler {
    private(set) var lastUsed: Date = .distantPast
    private(set) var lastUnused: Date = .distantPast
    private(set) var lastDrew: Date = .distantPast

    static let messageName = "pageSwipe"

    /// A wheel event that's mostly sideways is used if the page cancelled it, or something under the
    /// pointer (or the page) can scroll that way.
    static let script = WKUserScript(source: """
        (() => {
          const report = body => webkit.messageHandlers.\(messageName).postMessage(body);
          const canScroll = (element, deltaX) => {
            const max = element.scrollWidth - element.clientWidth;
            if (max <= 1) return false;
            const position = getComputedStyle(element).direction === 'rtl'
              ? max + element.scrollLeft : element.scrollLeft;
            return deltaX < 0 ? position > 1 : position < max - 1;
          };
          addEventListener('wheel', event => {
            if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
            const used = event.composedPath().some(node => node instanceof Element
                && /(auto|scroll)/.test(getComputedStyle(node).overflowX) && canScroll(node, event.deltaX))
              || (document.scrollingElement !== null && canScroll(document.scrollingElement, event.deltaX));
            // After the whole dispatch, so the page's own listeners have had their say.
            setTimeout(() => report(used || event.defaultPrevented ? 'used' : 'unused'));
          }, { passive: true });
          if (window !== top) return;
          const drew = () => requestAnimationFrame(() => report('drew'));
          try {
            new PerformanceObserver(list => {
              if (list.getEntries().some(entry => entry.name === 'first-contentful-paint')) drew();
            }).observe({ type: 'paint', buffered: true });
          } catch {}
          addEventListener('pageshow', event => { if (event.persisted) drew(); });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.body as? String {
        case "used": lastUsed = .now
        case "unused": lastUnused = .now
        case "drew": lastDrew = .now
        default: break
        }
    }
}

/// Lets clicks and scrolls through to the page under it.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The back/forward swipe over the page. Back slides the page off to the right, over a picture of the
/// page before it; forward slides a picture of the next page in over it. Back on a tab's first page
/// closes the tab, over a picture of the tab that will show. WebKit's own swipe is off (`MacTabChrome`).
final class PageSwipe {
    /// What the swipe needs of the tab on screen.
    struct Target {
        let webView: WKWebView
        let pictures: BackForwardPictures
        let script: PageSwipeScript
        /// The picture of the tab closing this one would show.
        let landing: () -> NSImage?
        let close: () -> Void
    }

    private enum Kind {
        case back, forward, close
    }

    private struct Gesture {
        let began = Date.now
        var across: CGFloat = 0
        var upDown: CGFloat = 0
        var sideways: Bool?
        /// Its last moves, for how fast the fingers were going when they lifted.
        var recent: [(time: TimeInterval, move: CGFloat)] = []
    }

    private struct Swipe {
        let kind: Kind
        let target: Target
        let stage: NSView
        let picture: CALayer
        let dim: CALayer
        let edge: CAGradientLayer
        let pill: NSView?
        var armed = false
    }

    private unowned let host: NSView
    private unowned let page: NSView
    private let target: () -> Target?
    private let restingFrame: () -> NSRect
    private let isOverPage: (NSEvent) -> Bool
    private var gesture: Gesture?
    private var swipe: Swipe?
    private var cover: NSView?
    /// The fingers' momentum after a swipe is the swipe's, not the page's.
    private var swallowsMomentum = false

    /// Fingers this far sideways start it; let go past this share of the width (or flick) and it goes.
    private static let start: CGFloat = 10
    private static let commit: CGFloat = 0.25
    private static let flick: CGFloat = 500
    /// How long to wait for the page to say whether it uses a sideways scroll before starting anyway
    /// (a PDF, where the script doesn't run).
    private static let pageAnswer: TimeInterval = 0.15

    /// The page is where the swipe moved it, not where layout puts it.
    var isSwiping: Bool { swipe != nil }

    init(host: NSView, page: NSView, target: @escaping () -> Target?, restingFrame: @escaping () -> NSRect,
         isOverPage: @escaping (NSEvent) -> Bool) {
        self.host = host
        self.page = page
        self.target = target
        self.restingFrame = restingFrame
        self.isOverPage = isOverPage
    }

    /// Follows a trackpad scroll; true when it's the swipe's, so the page doesn't get it too.
    func handle(_ event: NSEvent) -> Bool {
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            // A mouse wheel.
            cancel()
            return false
        }
        guard event.momentumPhase.isEmpty else { return swallowsMomentum }
        if event.phase == .began {
            cancel()
            removeCover()
            swallowsMomentum = false
            if isOverPage(event), target() != nil { gesture = Gesture() }
            return false
        }
        guard var current = gesture else { return false }
        if let swipe, target()?.webView !== swipe.target.webView {
            cancel()
            return false
        }
        if event.phase == .ended || event.phase == .cancelled {
            gesture = nil
            guard swipe != nil else { return false }
            let recent = current.recent.filter { event.timestamp - $0.time < 0.1 }
            finish(across: current.across, speed: recent.map(\.move).reduce(0, +) / 0.1,
                   cancelled: event.phase == .cancelled)
            // The page saw the gesture begin, so it sees it end.
            return false
        }
        // With natural scrolling the deltas go the fingers' way; without, the other way.
        let move = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        current.across += move
        current.upDown += abs(event.scrollingDeltaY)
        current.recent.append((event.timestamp, move))
        if current.recent.count > 12 { current.recent.removeFirst() }
        if current.sideways == nil, abs(current.across) + current.upDown > 6 {
            current.sideways = abs(current.across) > current.upDown * 2
        }
        gesture = current
        guard current.sideways == true, let target = swipe?.target ?? target() else {
            if current.sideways == false { gesture = nil }
            return false
        }
        // The page took it (a map, a carousel): it keeps the rest, and a swipe already started goes back.
        if target.script.lastUsed >= current.began {
            gesture = nil
            if swipe != nil { finish(across: 0, speed: 0, cancelled: true) }
            return false
        }
        if swipe == nil {
            let pageAnswered = target.script.lastUnused >= current.began
                || Date.now.timeIntervalSince(current.began) > Self.pageAnswer
            guard pageAnswered, abs(current.across) > Self.start, begin(back: current.across > 0, on: target)
            else { return false }
        }
        show(progress: progress(of: current.across))
        return true
    }

    /// Puts the page back where it was, at once: the window lost focus, or a new gesture began.
    func cancel() {
        gesture = nil
        if swipe != nil { tearDown() }
    }

    /// Keeps the picture over the page where the page is, as layout moves it.
    func placeCover() {
        cover?.frame = restingFrame()
    }

    private func progress(of across: CGFloat) -> CGFloat {
        guard let swipe else { return 0 }
        let toward = swipe.kind == .forward ? -across : across
        return min(max(toward / max(restingFrame().width, 1), 0), 1)
    }

    private func begin(back: Bool, on target: Target) -> Bool {
        let webView = target.webView
        let kind: Kind
        let image: NSImage?
        if back, webView.canGoBack {
            kind = .back
            image = target.pictures.picture(for: webView.backForwardList.backItem)
        } else if back {
            (kind, image) = (.close, target.landing())
        } else if webView.canGoForward {
            kind = .forward
            image = target.pictures.picture(for: webView.backForwardList.forwardItem)
        } else {
            return false
        }
        // For a swipe back to this page later.
        target.pictures.takePicture()

        let frame = restingFrame()
        let stage = PassThroughView(frame: frame)
        stage.wantsLayer = true
        stage.layer?.cornerRadius = 10
        stage.layer?.cornerCurve = .continuous
        stage.layer?.masksToBounds = true
        let picture = CALayer()
        picture.frame = CGRect(origin: .zero, size: frame.size)
        picture.backgroundColor = NSColor.textBackgroundColor.cgColor
        picture.contents = image
        picture.contentsGravity = .resize
        let dim = CALayer()
        dim.frame = picture.frame
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0
        let edge = CAGradientLayer()
        edge.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.22).cgColor]
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        edge.frame = CGRect(x: -18, y: 0, width: 18, height: frame.height)
        if kind == .forward {
            // The next page comes in over this one, which dims under it.
            picture.frame.origin.x = frame.width
            stage.layer?.addSublayer(dim)
            stage.layer?.addSublayer(edge)
            stage.layer?.addSublayer(picture)
            host.addSubview(stage, positioned: .above, relativeTo: page)
        } else {
            stage.layer?.addSublayer(picture)
            stage.layer?.addSublayer(dim)
            stage.layer?.addSublayer(edge)
            host.addSubview(stage, positioned: .below, relativeTo: page)
        }
        var pill: NSView?
        if kind == .close {
            let label = NSTextField(labelWithString: "✕  Close Tab")
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            let size = label.intrinsicContentSize
            let background = NSView(frame: NSRect(x: 12, y: (frame.height - 28) / 2, width: size.width + 22, height: 28))
            background.wantsLayer = true
            background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            background.layer?.cornerRadius = 14
            label.frame = NSRect(x: 11, y: (28 - size.height) / 2, width: size.width, height: size.height)
            background.addSubview(label)
            background.alphaValue = 0.55
            stage.addSubview(background)
            pill = background
        }
        swipe = Swipe(kind: kind, target: target, stage: stage, picture: picture, dim: dim, edge: edge, pill: pill)
        return true
    }

    /// Where everything sits `progress` of the way (0 to 1) to where the swipe goes.
    private func place(_ swipe: Swipe, at progress: CGFloat) {
        let frame = restingFrame()
        let width = frame.width
        switch swipe.kind {
        case .back, .close:
            page.frame.origin.x = frame.minX + width * progress
            swipe.picture.frame.origin.x = -0.24 * width * (1 - progress)
            swipe.dim.opacity = Float(0.18 * (1 - progress))
            swipe.edge.frame.origin.x = width * progress - swipe.edge.frame.width
        case .forward:
            swipe.picture.frame.origin.x = width * (1 - progress)
            swipe.dim.opacity = Float(0.18 * progress)
            swipe.edge.frame.origin.x = width * (1 - progress) - swipe.edge.frame.width
        }
    }

    private func show(progress: CGFloat) {
        guard var current = swipe else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(current, at: progress)
        CATransaction.commit()
        if current.kind == .close {
            let armed = progress >= Self.commit
            current.pill?.alphaValue = armed ? 1 : 0.55
            // The trackpad clicks when letting go would close the tab, and again if it no longer would.
            if armed != current.armed {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                current.armed = armed
            }
        }
        swipe = current
    }

    private func finish(across: CGFloat, speed: CGFloat, cancelled: Bool) {
        guard let current = swipe else { return }
        swallowsMomentum = true
        let forward = current.kind == .forward
        let toward = forward ? -speed : speed
        let distance = forward ? -across : across
        let goes = !cancelled && (progress(of: across) >= Self.commit && toward > -Self.flick
            || distance > 40 && toward > Self.flick)
        let duration = goes ? 0.16 : 0.2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            place(current, at: goes ? 1 : 0)
            CATransaction.commit()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.swipe?.stage === current.stage else { return }
                if goes { self.arrive(current) } else { self.tearDown() }
            }
        }
    }

    /// Goes there, with the picture of where it went up until the page itself has drawn.
    private func arrive(_ swipe: Swipe) {
        removeCover()
        let cover = PassThroughView(frame: restingFrame())
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 10
        cover.layer?.cornerCurve = .continuous
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        cover.layer?.contents = swipe.picture.contents
        cover.layer?.contentsGravity = .resize
        host.addSubview(cover, positioned: .above, relativeTo: page)
        self.cover = cover
        tearDown()
        let webView = swipe.target.webView
        let script = swipe.target.script
        let leaving = webView.backForwardList.currentItem
        let left = Date.now
        switch swipe.kind {
        case .back: webView.goBack()
        case .forward: webView.goForward()
        case .close: swipe.target.close()
        }
        Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.cover === cover else { return }
                let shown = self.target()?.webView
                let arrived = switch swipe.kind {
                case .back, .forward:
                    // WebKit's back can skip pages a site added on its own, so anywhere else counts.
                    shown !== webView || webView.backForwardList.currentItem !== leaving
                        && (!webView.isLoading || script.lastDrew >= left)
                case .close: shown !== webView && shown?.isLoading != true
                }
                if arrived { break }
            }
            // A frame for it to draw.
            try? await Task.sleep(for: .milliseconds(60))
            guard self?.cover === cover else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                cover.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.cover === cover { self?.removeCover() }
                }
            }
        }
    }

    private func removeCover() {
        cover?.removeFromSuperview()
        cover = nil
    }

    private func tearDown() {
        swipe?.stage.removeFromSuperview()
        swipe = nil
        page.frame = restingFrame()
    }
}
