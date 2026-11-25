import AppKit
import CormorantBrowser
import CormorantCore
import SwiftUI
import WebKit

/// How long the sidebar takes to slide in or out, the page's edge with it.
private let sidebarSlideDuration = 0.08

/// The Space's color behind everything, the sidebar on it and the page set in from the edges. With
/// the sidebar hidden the page fills the frame and the window's buttons go with the sidebar, so the
/// page never moves up or down; pointing at the left edge slides the sidebar over the page.
struct BrowserWindow: View {
    let store: BrowserStore
    let commands: WindowCommands
    let platform: MacBrowserPlatform
    @State private var peeksSidebar = false
    /// The slide-out sidebar on screen, and its window buttons, which come once it's in place.
    @State private var peekIsOut = false
    @State private var peekHasButtons = false
    /// Whether the docked sidebar is out and the page beside it: the two slide together.
    @State private var isDocked: Bool
    /// How far a two-finger swipe over the sidebar has carried it toward a neighbouring Space.
    @State private var swipe: CGFloat = 0
    /// A swipe let go to switch, sliding the rest of the way: switched to at once if anything else
    /// happens first.
    @State private var pendingSwitch: (to: UUID, from: UUID)?
    /// The docked sidebar is out and done sliding.
    @State private var dockIsSettled: Bool
    /// The last Archive or Delete Space confirmation's title, kept while it closes.
    @State private var removalTitle = ""
    /// Where the command bar was dragged from its place, while it's up.
    @State private var barMove: CGSize = .zero
    @GestureState private var barDrag: CGSize = .zero
    /// The command bar's frame, so a click outside it can put it away.
    @State private var barFrame: CGRect = .zero
    @Environment(\.colorScheme) private var colorScheme

    init(store: BrowserStore, commands: WindowCommands, platform: MacBrowserPlatform) {
        self.store = store
        self.commands = commands
        self.platform = platform
        _isDocked = State(initialValue: commands.showsSidebar)
        _dockIsSettled = State(initialValue: commands.showsSidebar)
    }

    private static let slide = Animation.easeOut(duration: sidebarSlideDuration)

    var body: some View {
        GeometryReader { proxy in
            // None in full screen; the controls row keeps its height.
            let titleBar = max(proxy.safeAreaInsets.top, 28)
            let pageLeading = isDocked ? commands.sidebarWidth : 8
            ZStack(alignment: .topLeading) {
                PageArea(store: store, webView: store.activeSession?.webView, leading: pageLeading, platform: platform,
                         swipeTarget: pageSwipeTarget)
                PageOverlays(store: store)
                    .padding(8)
                    .padding(.leading, pageLeading - 8)
                // In the margin above the page, so the page never moves for it.
                if let session = store.activeSession, session.isLoading {
                    LoadingIndicator(color: store.state.activeSpace.color.loadingColor(dark: colorScheme == .dark),
                                     progress: session.progress)
                        .id(session.tabID)
                        .position(x: pageLeading + (proxy.size.width - pageLeading - 8) / 2, y: 4)
                        .transition(.opacity)
                }
                Sidebar(store: store, commands: commands, titleBarHeight: titleBar, presentsSpaceEditor: dockIsSettled,
                        swipe: swipe)
                    .frame(width: commands.sidebarWidth)
                    .background(spaceTint)
                    .overlay(alignment: .trailing) { SidebarResizer(commands: commands).allowsHitTesting(isDocked) }
                    // Away, its edge keeps pace with the page's.
                    .offset(x: isDocked ? 0 : 8 - commands.sidebarWidth)
                    .accessibilityHidden(!commands.showsSidebar)
                if peekIsOut {
                    Sidebar(store: store, commands: commands, titleBarHeight: max(titleBar - 8, 28),
                            presentsSpaceEditor: peekHasButtons && !commands.showsSidebar, swipe: swipe)
                        .frame(width: commands.sidebarWidth)
                        .background(spaceTint, in: .rect(cornerRadius: 12))
                        .clipShape(.rect(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.25), radius: 25, y: 9)
                        .padding(8)
                        .transition(.move(edge: .leading))
                }
                if commands.isFinding, let session = store.activeSession {
                    FindBar(webView: session.webView, commands: commands)
                        .id(session.tabID)
                        .offset(x: proxy.size.width - 8 - 12 - FindBar.width, y: 20)
                        .transition(.opacity)
                }
                if let mode = barMode {
                    let pageWidth = proxy.size.width - pageLeading - 8
                    let width = mode == .newTab ? min(860, pageWidth - 64) : min(720, proxy.size.width - 16)
                    // ⌘T's over the middle of the page; ⌘L's out of the sidebar, where the host is.
                    let place = CGPoint(x: mode == .newTab ? pageLeading + (pageWidth - width) / 2 : commands.showsSidebar ? 10 : 8,
                                        y: mode == .newTab ? proxy.size.height * 0.16 : commands.showsSidebar ? titleBar + 6 : 8)
                    let moved = barMove
                    CommandBar(mode: mode, store: store, dismiss: dismissBar)
                        .id(mode)
                        .frame(width: width)
                        // Before the offset: measured after it, the frame leaves the offset out.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { barFrame = $0 }
                        .offset(x: place.x + moved.width + barDrag.width, y: place.y + moved.height + barDrag.height)
                        // By anything but the field, which keeps its own drags for selecting text.
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .updating($barDrag) { drag, state, _ in state = drag.translation }
                            .onEnded { drag in
                                let x = min(max(place.x + moved.width + drag.translation.width, 8), proxy.size.width - width - 8)
                                let y = min(max(place.y + moved.height + drag.translation.height, 8), proxy.size.height - 80)
                                barMove = CGSize(width: x - place.x, height: y - place.y)
                            })
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: mode == .newTab ? .top : .topLeading)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: barMode)
            .animation(.easeOut(duration: 0.2), value: store.activeSession?.isLoading == true)
            .background(spaceTint)
            .background(WindowChrome(showsButtons: commands.showsSidebar || peekHasButtons) { x in
                // From the pointer, not hover on views that move under it: out near the left edge,
                // away only well clear of it.
                // Not while a Space editor hangs off it.
                guard !commands.showsSidebar, commands.spaceEditor == nil else { return }
                if x <= 16 {
                    peeksSidebar = true
                } else if x > commands.sidebarWidth + 32 {
                    peeksSidebar = false
                }
            } pointerPressed: { point in
                // Nothing covers the page while the bar is up, so it still scrolls; a click outside the
                // bar puts it away and goes on to what was clicked.
                if barMode != nil, !barFrame.contains(point) { dismissBar() }
            } sidebarReach: {
                // Not under the ⌘T/⌘L bar, which a swipe would otherwise switch away from.
                guard barMode == nil else { return nil }
                return commands.showsSidebar ? commands.sidebarWidth : peekIsOut ? commands.sidebarWidth + 8 : nil
            } swipedSidebar: { swiped in
                followSwipe(swiped)
            })
            .ignoresSafeArea()
        }
        .onChange(of: commands.showsSidebar) { _, shows in
            peeksSidebar = false
            dockIsSettled = false
            if !shows { commands.spaceEditor = nil }
            withAnimation(Self.slide) { isDocked = shows } completion: {
                dockIsSettled = isDocked
            }
        }
        .onChange(of: barMode) { barMove = .zero }
        .onChange(of: commands.spaceRemoval?.title) { _, title in if let title { removalTitle = title } }
        .onChange(of: store.state.activeTabID) {
            commands.isFinding = false
            commands.isEditingAddress = false
        }
        .onChange(of: store.isComposingNewTab) { _, composing in
            if composing { commands.isEditingAddress = false }
        }
        .onChange(of: peekShown) { _, shown in
            peekHasButtons = false
            withAnimation(Self.slide) { peekIsOut = shown } completion: {
                peekHasButtons = peekIsOut
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onChange(of: store.previewedDownload) { _, file in
            guard let file else { return }
            NSWorkspace.shared.open(file)
            store.previewedDownload = nil
        }
        .onChange(of: store.showsDownloads) { _, shows in
            guard shows else { return }
            if let newest = store.downloads.listed.first(where: { $0.status == .finished }) {
                NSWorkspace.shared.activateFileViewerSelecting([newest.fileURL])
            }
            store.showsDownloads = false
        }
        .alert(commands.spaceRemoval?.title ?? removalTitle,
               isPresented: Binding(get: { commands.spaceRemoval != nil }, set: { if !$0 { commands.spaceRemoval = nil } }),
               presenting: commands.spaceRemoval) { removal in
            switch removal.kind {
            case .archive: Button("Archive") { store.archiveSpace(removal.spaceID) }
            case .delete: Button("Delete", role: .destructive) { store.deleteSpace(removal.spaceID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
        .alert("Couldn't read saved tabs.", isPresented: Binding(get: { store.loadFailure != nil }, set: { _ in })) {
            Button("Start Fresh") { store.startFresh() }
        } message: {
            if let name = store.loadFailure?.keptCopyName {
                Text("A copy was kept at \(name).")
            } else {
                Text("No copy could be kept. Starting fresh replaces them.")
            }
        }
    }

    private var barMode: CommandBar.Mode? {
        if store.isComposingNewTab { return .newTab }
        return commands.isEditingAddress ? .editAddress : nil
    }

    private func dismissBar() {
        store.cancelComposing()
        commands.isEditingAddress = false
        // Keys go back to the page, so Space and the arrows scroll it; once a new tab's is in place.
        Task {
            guard let webView = store.activeSession?.webView else { return }
            webView.window?.makeFirstResponder(webView)
        }
    }

    private var peekShown: Bool {
        !commands.showsSidebar && peeksSidebar
    }

    /// The active Space's tint, blending toward the neighbour's as a swipe brings it in.
    private var spaceTint: Color {
        let dark = colorScheme == .dark
        let tint = store.state.activeSpace.color.windowTint(dark: dark)
        guard swipe != 0, let neighbour = swipeTarget(towardNext: swipe < 0) else { return tint.color }
        let progress = min(abs(swipe) / commands.sidebarWidth, 1)
        return tint.mixed(with: neighbour.color.windowTint(dark: dark), amount: progress).color
    }

    /// The tab on screen, for the back/forward swipe over the page.
    private func pageSwipeTarget() -> PageSwipe.Target? {
        guard barMode == nil, let session = store.activeSession, let chrome = session.chrome as? MacTabChrome
        else { return nil }
        let tabID = session.tabID
        return PageSwipe.Target(
            webView: session.webView, pictures: chrome.pictures, script: chrome.swipeScript,
            landing: { store.backSwipeSnapshot(for: tabID).map { NSImage(cgImage: $0.content, size: .zero) } },
            close: { store.close(tabID) })
    }

    private func swipeTarget(towardNext: Bool) -> Space? {
        let spaces = store.state.shownSpaces
        guard let index = spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }) else { return nil }
        let target = index + (towardNext ? 1 : -1)
        return spaces.indices.contains(target) ? spaces[target] : nil
    }

    /// The sidebar follows the fingers; let go far enough (or quickly enough) and the Space switches,
    /// once its neighbour has slid all the way in. Past the first or last Space it only gives a little.
    private func followSwipe(_ swiped: SidebarSwipe) {
        let width = commands.sidebarWidth
        switch swiped {
        case .moved(let across):
            finishPendingSwitch()
            swipe = swipeTarget(towardNext: across < 0) == nil ? across / 6 : min(max(across, -width), width)
        case .ended(let across, let speed):
            // A flick needs some distance, and a fast move back the other way calls it off.
            let flicked = abs(across) > 40 && abs(speed) > 700 && (speed < 0) == (across < 0)
            let flickedBack = abs(speed) > 700 && (speed < 0) != (across < 0)
            guard let target = swipeTarget(towardNext: across < 0), !flickedBack,
                  abs(across) > width / 3 || flicked else {
                withAnimation(.snappy(duration: 0.2)) { swipe = 0 }
                return
            }
            let end = across < 0 ? -width : width
            pendingSwitch = (target.id, store.state.activeSpaceID)
            guard swipe != end else { return finishPendingSwitch() }
            withAnimation(.easeOut(duration: 0.18)) { swipe = end } completion: { finishPendingSwitch() }
        }
    }

    private func finishPendingSwitch() {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        var settle = Transaction()
        settle.disablesAnimations = true
        withTransaction(settle) {
            if store.state.activeSpaceID == pending.from { store.switchToSpace(pending.to) }
            swipe = 0
        }
    }
}

/// The window's own buttons, shown only with the sidebar; the window dragged by its background; where
/// the pointer is and is pressed across the window (top-left origin), page included; and two-finger
/// swipes over the sidebar.
private struct WindowChrome: NSViewRepresentable {
    let showsButtons: Bool
    let pointerMoved: (CGFloat) -> Void
    let pointerPressed: (CGPoint) -> Void
    /// Where the sidebar on screen ends, nil with none: two fingers swiped sideways over it switch Space.
    let sidebarReach: () -> CGFloat?
    let swipedSidebar: (SidebarSwipe) -> Void

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.showsButtons = showsButtons
        view.pointerMoved = pointerMoved
        view.pointerPressed = pointerPressed
        view.sidebarReach = sidebarReach
        view.swipedSidebar = swipedSidebar
    }

    final class ChromeView: NSView {
        var showsButtons = true {
            didSet { apply() }
        }
        var pointerMoved: ((CGFloat) -> Void)?
        var pointerPressed: ((CGPoint) -> Void)?
        var sidebarReach: (() -> CGFloat?)?
        var swipedSidebar: ((SidebarSwipe) -> Void)?
        /// The swipe under way over the sidebar: how far the fingers went across and up or down, which
        /// way it was settled to be, its last moves (for its speed when the fingers lift), and the
        /// sidebar's width.
        private var swipe: (across: CGFloat, upDown: CGFloat, sideways: Bool?, recent: [(CFTimeInterval, CGFloat)], width: CGFloat)?
        /// After a sideways swipe, until the next gesture: its momentum isn't the list's to scroll.
        private var swallowsMomentum = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .scrollWheel]) {
                [weak self] event in
                guard let self, event.window === self.window else { return event }
                let location = event.locationInWindow
                if event.type == .scrollWheel {
                    return swiped(event) ? nil : event
                } else if event.type == .leftMouseDown {
                    let height = self.window?.contentView?.bounds.height ?? 0
                    pointerPressed?(CGPoint(x: location.x, y: height - location.y))
                } else {
                    pointerMoved?(location.x)
                }
                return event
            }
            apply()
        }

        /// Follows a trackpad swipe over the sidebar; true once it's settled as sideways, so the
        /// sidebar's list doesn't scroll with it (or drift with its momentum after).
        private func swiped(_ event: NSEvent) -> Bool {
            if event.phase.isEmpty, event.momentumPhase.isEmpty {
                // A mouse wheel: no gesture to follow, and one cut off mid-way is over.
                if swipe?.sideways == true { swipedSidebar?(.ended(0, speed: 0)) }
                swipe = nil
                return false
            }
            if !event.momentumPhase.isEmpty { return swallowsMomentum }
            if event.phase == .began {
                swipe = nil
                swallowsMomentum = false
                if let reach = sidebarReach?(), event.locationInWindow.x <= reach { swipe = (0, 0, nil, [], reach) }
            }
            guard var current = swipe else { return false }
            if event.phase == .ended || event.phase == .cancelled {
                swipe = nil
                guard current.sideways == true else { return false }
                swallowsMomentum = true
                let now = event.timestamp
                let recent = current.recent.filter { now - $0.0 < 0.1 }
                swipedSidebar?(.ended(current.across, speed: recent.map(\.1).reduce(0, +) / 0.1))
                // On to the list too, which saw the gesture begin and should see it end.
                return false
            }
            // With natural scrolling the deltas go the fingers' way; without, the other way.
            let move = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            // No further than a page either way, so coming back answers at once.
            current.across = min(max(current.across + move, -current.width), current.width)
            current.upDown += abs(event.scrollingDeltaY)
            current.recent.append((event.timestamp, move))
            if current.recent.count > 12 { current.recent.removeFirst() }
            if current.sideways == nil, abs(current.across) + current.upDown > 6 {
                current.sideways = abs(current.across) > current.upDown * 2
            }
            swipe = current
            guard current.sideways == true else { return false }
            swipedSidebar?(.moved(current.across))
            return true
        }

        private func apply() {
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(button)?.isHidden = !showsButtons
            }
        }
    }
}

/// Background tabs' web views: never clicked or read by VoiceOver.
private final class StageView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

fileprivate enum SidebarSwipe {
    /// How far the fingers have gone, right positive.
    case moved(CGFloat)
    /// Lifted, with their speed (points a second) just before.
    case ended(CGFloat, speed: CGFloat)
}

/// The sidebar's trailing edge, dragged to make it wider or narrower.
private struct SidebarResizer: View {
    let commands: WindowCommands
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startWidth ?? commands.sidebarWidth
                    startWidth = start
                    commands.sidebarWidth = min(max(start + drag.translation.width, 200), 480)
                }
                .onEnded { _ in startWidth = nil })
            .offset(x: 3)
    }
}

/// A short bar of the Space's color breathing while the page loads. A load still going after one
/// breath (a big PDF) shows how much has arrived: at the breath's dimmest the bar becomes the track,
/// at that same dim level, and the part that's arrived carries on breathing.
private struct LoadingIndicator: View {
    let color: Color
    let progress: Double
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 80
    private static let breath: TimeInterval = 1.2
    private static let dim = 0.35

    var body: some View {
        // Brightness from the clock, not a repeating animation, so each shape's is exact every frame.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : nil)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let showsProgress = elapsed >= Self.breath
            let breathing = reduceMotion ? 0.8 : Self.dim + (1 - Self.dim) * (0.5 - 0.5 * cos(2 * .pi * elapsed / Self.breath))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .opacity(showsProgress ? Self.dim : breathing)
                Capsule()
                    .fill(color)
                    .frame(width: showsProgress ? Self.width * max(progress, 0.06) : 0)
                    // Over the track: together they make `breathing`, the track alone where it's at its dimmest.
                    .opacity((breathing - Self.dim) / (1 - Self.dim))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
            .frame(width: Self.width, height: 3)
            .accessibilityElement()
            .accessibilityLabel("Loading")
            .accessibilityValue(showsProgress ? Text(progress, format: .percent.precision(.fractionLength(0))) : Text(""))
        }
    }
}

/// Toasts, along the bottom of the page.
private struct PageOverlays: View {
    let store: BrowserStore

    var body: some View {
        ZStack {
            if let toast = store.toast {
                ToastView(toast: toast, store: store)
                    .padding(.bottom, 18)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 10))
        .allowsHitTesting(store.toast != nil)
        .animation(.snappy(duration: 0.2), value: store.toast?.id)
    }
}

/// Back · the Space's badge and the message · the buttons, on dark glass.
private struct ToastView: View {
    let toast: Toast
    let store: BrowserStore

    var body: some View {
        HStack(spacing: 10) {
            if let back = toast.leadingAction { button(back) }
            icon
            Text(toast.message)
                .lineLimit(1)
                .accessibilityLabel(toast.spokenText ?? toast.message)
            ForEach(toast.actions) { button($0) }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(.white)
        .padding(.vertical, 7)
        .padding(.leading, toast.leadingAction == nil ? 14 : 7)
        .padding(.trailing, toast.actions.isEmpty ? 14 : 7)
        .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.9), in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 15, y: 10)
        .onHover { store.holdToast($0) }
    }

    @ViewBuilder private var icon: some View {
        switch toast.icon {
        case .space(let space): SpaceBadge(space: space, side: 20)
        case .symbol(let name): Image(systemName: name)
        case .incognito: Image(systemName: "sunglasses")
        }
    }

    private func button(_ action: Toast.Action) -> some View {
        Button {
            action.perform()
            store.dismissToast(toast.id)
        } label: {
            HStack(spacing: 5) {
                if let space = action.space {
                    Image(systemName: "chevron.left")
                    SpaceBadge(space: space, side: 16)
                } else {
                    Text(action.title)
                }
            }
            .fontWeight(.semibold)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.white.opacity(0.16), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }
}

/// The page, set in from the window's edges, in AppKit: SwiftUI only sets a web view's final frame,
/// and an animated frame would stretch a picture of the page. When its edge slides with the
/// sidebar, it's resized on every display frame, its right edge staying put.
private struct PageArea: NSViewRepresentable {
    let store: BrowserStore
    let webView: WKWebView?
    let leading: CGFloat
    let platform: MacBrowserPlatform
    let swipeTarget: () -> PageSwipe.Target?

    func makeNSView(context: Context) -> PageAreaView {
        let view = PageAreaView(cover: PageCoverView(rootView: PageCover(store: store)))
        platform.backgroundStage = view
        return view
    }

    func updateNSView(_ view: PageAreaView, context: Context) {
        view.swipeTarget = swipeTarget
        view.show(webView)
        view.setLeading(leading, animated: context.transaction.animation != nil)
    }

    /// Background tabs load on `stage`, at the page's size so they need no relayout once shown, just
    /// past the window's right edge: in the window, so WebKit loads and lays them out, but where no
    /// pointer reaches (a tracking area only counts what's visible) and nothing shows.
    final class PageAreaView: NSView, BackgroundTabStage {
        private let page = NSView()
        /// Over the web view, in the page so it slides and rounds with it: the wash and the bird.
        private let cover: PageCoverView
        private let stage = StageView()
        private var webView: WKWebView?
        private var leading: CGFloat = 8
        /// Where the page's leading edge is drawn: `leading` itself, or on its way there.
        private var shownLeading: CGFloat = 8
        private var slide: (from: CGFloat, start: CFTimeInterval)?
        private var displayLink: CADisplayLink?
        var swipeTarget: () -> PageSwipe.Target? = { nil }
        private lazy var swipe = PageSwipe(host: self, page: page, target: { [unowned self] in swipeTarget() },
                                           restingFrame: { [unowned self] in restingPageFrame },
                                           isOverPage: { [unowned self] in isOverPage($0) })
        private var monitor: Any?
        private var focusObservers: [NSObjectProtocol] = []

        init(cover: PageCoverView) {
            self.cover = cover
            super.init(frame: .zero)
            cover.sizingOptions = []
            cover.autoresizingMask = [.width, .height]
            page.addSubview(cover)
            page.wantsLayer = true
            page.layer?.cornerRadius = 10
            page.layer?.cornerCurve = .continuous
            page.layer?.masksToBounds = true
            page.layer?.borderWidth = 0.5
            addSubview(stage)
            addSubview(page)
            updateColors()
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        /// The session owns its web view, so the one on screen is swapped in rather than rebuilt.
        func show(_ newWebView: WKWebView?) {
            guard newWebView !== webView else { return }
            if webView?.superview === page { webView?.removeFromSuperview() }
            webView = newWebView
            if let newWebView {
                newWebView.frame = page.bounds
                page.addSubview(newWebView, positioned: .below, relativeTo: cover)
            }
        }

        var holdsTabs: Bool { window != nil }

        func add(_ webView: WKWebView) {
            webView.frame = stage.bounds
            stage.addSubview(webView)
        }

        func remove(_ webView: WKWebView) {
            if webView.superview === stage { webView.removeFromSuperview() }
        }

        func setLeading(_ newLeading: CGFloat, animated: Bool) {
            guard newLeading != leading else { return }
            leading = newLeading
            guard animated, window != nil else {
                slide = nil
                shownLeading = newLeading
                needsLayout = true
                return
            }
            slide = (from: shownLeading, start: CACurrentMediaTime())
            if displayLink == nil {
                displayLink = displayLink(target: self, selector: #selector(step))
                displayLink?.add(to: .main, forMode: .common)
            }
        }

        @objc private func step(_ link: CADisplayLink) {
            guard let slide else { return stopSliding() }
            let progress = min((CACurrentMediaTime() - slide.start) / sidebarSlideDuration, 1)
            shownLeading = slide.from + (leading - slide.from) * Self.easeOut(progress)
            placePage()
            if progress >= 1 { stopSliding() }
        }

        private func stopSliding() {
            slide = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            focusObservers.forEach(NotificationCenter.default.removeObserver)
            focusObservers = []
            guard let window else { return stopSliding() }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === window else { return event }
                if event.type == .leftMouseDown {
                    // Picture the page now, in case the click is on a link and it goes.
                    if isOverPage(event) { swipeTarget()?.pictures.takePicture() }
                    return event
                }
                if swipe.handle(event) { return nil }
                if event.phase == .ended || event.momentumPhase == .ended, isOverPage(event) {
                    swipeTarget()?.pictures.takePicture(after: .milliseconds(300))
                }
                return event
            }
            // A swipe that loses its fingers' events puts the page back.
            focusObservers = [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: $0 == NSWindow.didResignKeyNotification ? window : nil,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.swipe.cancel() }
                }
            }
        }

        /// The event is over the page itself, not something drawn over it (the sidebar, a bar, a toast).
        private func isOverPage(_ event: NSEvent) -> Bool {
            guard let webView, let content = window?.contentView else { return false }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            return content.hitTest(point)?.isDescendant(of: webView) == true
        }

        override func layout() {
            super.layout()
            if slide == nil { shownLeading = leading }
            placePage()
        }

        private var restingPageFrame: NSRect {
            NSRect(x: shownLeading, y: 8, width: max(bounds.width - shownLeading - 8, 0), height: max(bounds.height - 16, 0))
        }

        private func placePage() {
            if !swipe.isSwiping { page.frame = restingPageFrame }
            swipe.placeCover()
            webView?.frame = page.bounds
            cover.frame = page.bounds
            // The size the page will have once the sidebar's slide is done, not on its way.
            let size = NSSize(width: max(bounds.width - leading - 8, 0), height: page.frame.height)
            if stage.frame.size != size || stage.frame.minX != bounds.width + 64 {
                stage.frame = NSRect(origin: NSPoint(x: bounds.width + 64, y: 8), size: size)
                for staged in stage.subviews { staged.frame = stage.bounds }
            }
        }

        /// SwiftUI's `easeOut`, the sidebar's curve: the cubic Bézier through (0, 0), (0.58, 1).
        private static func easeOut(_ time: Double) -> Double {
            // Solve x(t) = time for t by Newton's method, then return y(t).
            var t = time
            for _ in 0..<8 {
                let x = 3 * (1 - t) * t * t * 0.58 + t * t * t
                let slope = 6 * (1 - t) * t * 0.58 + 3 * t * t * 0.42
                guard abs(x - time) > 1e-5, slope > 1e-6 else { break }
                t = min(max(t - (x - time) / slope, 0), 1)
            }
            return 3 * (1 - t) * t * t + t * t * t
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                page.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                page.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.14)).cgColor
            }
        }
    }
}
