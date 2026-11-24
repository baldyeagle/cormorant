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
    @State private var peeksSidebar = false
    /// The slide-out sidebar on screen, and its window buttons, which come once it's in place.
    @State private var peekIsOut = false
    @State private var peekHasButtons = false
    /// Whether the docked sidebar is out and the page beside it: the two slide together.
    @State private var isDocked: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(store: BrowserStore, commands: WindowCommands) {
        self.store = store
        self.commands = commands
        _isDocked = State(initialValue: commands.showsSidebar)
    }

    private static let slide = Animation.easeOut(duration: sidebarSlideDuration)

    var body: some View {
        GeometryReader { proxy in
            // None in full screen; the controls row keeps its height.
            let titleBar = max(proxy.safeAreaInsets.top, 28)
            let pageLeading = isDocked ? commands.sidebarWidth : 8
            ZStack(alignment: .topLeading) {
                PageArea(webView: store.isComposingNewTab ? nil : store.activeSession?.webView, leading: pageLeading)
                PageOverlays(store: store)
                    .padding(8)
                    .padding(.leading, pageLeading - 8)
                // In the margin above the page, so the page never moves for it.
                if let session = store.activeSession, session.isLoading, !store.isComposingNewTab {
                    LoadingIndicator(color: store.state.activeSpace.color.loadingColor(dark: colorScheme == .dark),
                                     progress: session.progress)
                        .id(session.tabID)
                        .position(x: pageLeading + (proxy.size.width - pageLeading - 8) / 2, y: 4)
                        .transition(.opacity)
                }
                Sidebar(store: store, commands: commands, titleBarHeight: titleBar, isShown: commands.showsSidebar)
                    .frame(width: commands.sidebarWidth)
                    .background(spaceTint)
                    .overlay(alignment: .trailing) { SidebarResizer(commands: commands).allowsHitTesting(isDocked) }
                    // Away, its edge keeps pace with the page's.
                    .offset(x: isDocked ? 0 : 8 - commands.sidebarWidth)
                    .accessibilityHidden(!commands.showsSidebar)
                if peekIsOut {
                    Sidebar(store: store, commands: commands, titleBarHeight: max(titleBar - 8, 28), isShown: true)
                        .frame(width: commands.sidebarWidth)
                        .background(spaceTint, in: .rect(cornerRadius: 12))
                        .clipShape(.rect(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.25), radius: 25, y: 9)
                        .padding(8)
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.activeSession?.isLoading == true && !store.isComposingNewTab)
            .background(spaceTint)
            .background(WindowChrome(showsButtons: commands.showsSidebar || peekHasButtons) { x in
                // From the pointer, not hover on views that move under it: out near the left edge,
                // away only well clear of it.
                guard !commands.showsSidebar else { return }
                if x <= 16 {
                    peeksSidebar = true
                } else if x > commands.sidebarWidth + 32 {
                    peeksSidebar = false
                }
            })
            .ignoresSafeArea()
        }
        .onChange(of: commands.showsSidebar) { _, shows in
            peeksSidebar = false
            withAnimation(Self.slide) { isDocked = shows }
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

    private var peekShown: Bool {
        !commands.showsSidebar && (peeksSidebar || store.isComposingNewTab || commands.isEditingAddress)
    }

    private var spaceTint: Color {
        store.state.activeSpace.color.windowTint(dark: colorScheme == .dark)
    }
}

/// The window's own buttons, shown only with the sidebar; the window dragged by its background; and where
/// the pointer is across the window, page included.
private struct WindowChrome: NSViewRepresentable {
    let showsButtons: Bool
    let pointerMoved: (CGFloat) -> Void

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.showsButtons = showsButtons
        view.pointerMoved = pointerMoved
    }

    final class ChromeView: NSView {
        var showsButtons = true {
            didSet { apply() }
        }
        var pointerMoved: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                if let self, event.window === self.window { pointerMoved?(event.locationInWindow.x) }
                return event
            }
            apply()
        }

        private func apply() {
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(button)?.isHidden = !showsButtons
            }
        }
    }
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
    let webView: WKWebView?
    let leading: CGFloat

    func makeNSView(context: Context) -> PageAreaView { PageAreaView() }

    func updateNSView(_ view: PageAreaView, context: Context) {
        view.show(webView)
        view.setLeading(leading, animated: context.transaction.animation != nil)
    }

    final class PageAreaView: NSView {
        private let page = NSView()
        private var webView: WKWebView?
        private var leading: CGFloat = 8
        /// Where the page's leading edge is drawn: `leading` itself, or on its way there.
        private var shownLeading: CGFloat = 8
        private var slide: (from: CGFloat, start: CFTimeInterval)?
        private var displayLink: CADisplayLink?

        override init(frame: NSRect) {
            super.init(frame: frame)
            page.wantsLayer = true
            page.layer?.cornerRadius = 10
            page.layer?.cornerCurve = .continuous
            page.layer?.masksToBounds = true
            page.layer?.borderWidth = 0.5
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
                page.addSubview(newWebView)
            }
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
            if window == nil { stopSliding() }
        }

        override func layout() {
            super.layout()
            if slide == nil { shownLeading = leading }
            placePage()
        }

        private func placePage() {
            page.frame = NSRect(x: shownLeading, y: 8, width: max(bounds.width - shownLeading - 8, 0),
                                height: max(bounds.height - 16, 0))
            webView?.frame = page.bounds
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
