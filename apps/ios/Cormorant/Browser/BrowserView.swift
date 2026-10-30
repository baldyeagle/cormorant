import CormorantCore
import SwiftUI

/// The main screen: the active tab's web view under a bottom bar, with the search panel and the
/// page-actions sheet on top.
struct BrowserView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSwitcher = false
    @State private var showActions = false
    @State private var isSearching = false
    @State private var barHeight: CGFloat = 0
    /// The search panel's top edge in global coordinates, once it has laid out; the empty state keeps
    /// its mark above it.
    @State private var searchPanelTop: CGFloat?
    /// A keyboard is on screen. The bar (and download banner) stay put underneath it (see
    /// `.ignoresSafeArea(.keyboard)`), and VoiceOver mustn't find them in among a page's form fields.
    @State private var keyboardCoversBar = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            if let session = store.activeSession {
                // Below the status bar; under the bottom bar so its inset scrolls the page clear of it.
                WebViewContainer(webView: session.webView, barHeight: barHeight,
                                 backSwipeClose: backSwipeClose(for: session))
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard)
            }
            // Also while tabs load, so the launch screen's bird stays put until there's something to show.
            if !store.isLoaded || store.activeTab?.url == nil {
                emptyState
            }
            if let session = store.activeSession, let error = session.loadError {
                LoadErrorView(error: error, onRetry: session.retry)
            }
        }
        // Full size even before tabs load: an empty ZStack collapses to a point at the center, and
        // the bar inset attached to it would render mid-screen and then jump down.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let session = store.activeSession, let url = session.blockedDownloadURL {
                DownloadBanner(url: url) { session.blockedDownloadURL = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Under the keyboard with the bar.
                    .accessibilityHidden(keyboardCoversBar)
            }
        }
        .animation(.snappy, value: store.activeSession?.blockedDownloadURL)
        .background {
            // Fills the status-bar strip.
            StatusBarStrip(tint: chromeTint, tabID: store.activeTab?.id,
                           fades: store.activeSession?.pageColors.fades ?? false,
                           isStale: chromeTintIsStale, colorScheme: colorScheme)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                FindOnPageBar(session: store.activeSession)
                BottomBar(
                    session: store.activeSession,
                    url: store.activeTab?.url,
                    isSearching: isSearching,
                    showSwitcher: presentSwitcher,
                    showActions: presentActions
                )
                // Beyond this the three controls stop fitting on one line on a phone. Applied out
                // here so the bar's @ScaledMetric sizes are capped along with its fonts.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                // The search panel replaces the bar while it's up; never two address controls at once.
                // Hidden (but laid out) until tabs load, so it never flashes a 0 count first.
                .opacity(isSearching || !store.isLoaded ? 0 : 1)
                .allowsHitTesting(!isSearching && store.isLoaded)
                .accessibilityHidden(isSearching || !store.isLoaded || keyboardCoversBar)
            }
            // Insets track the EXPANDED bar only. Shrinking them when the bar collapses would move
            // the content, and at the end of a page that offset clamp reads as a scroll-up, which
            // re-expands the bar, which shrinks the content again: a visible flicker.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if store.activeSession?.isBarCollapsed != true, height > 0 { barHeight = height }
            }
        }
        // The bar never moves for the keyboard (no mid-screen bar while the keyboard animates at
        // launch, none riding up over page form fields); only the search panel avoids it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Read from every keyboard frame change rather than paired show/hide events, so the bar
        // comes back however the keyboard leaves.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            guard let message = UIResponder.KeyboardWillChangeFrameMessage.makeMessage($0) else { return }
            keyboardCoversBar = !message.endFrame.isEmpty && message.endFrame.minY < message.screen.bounds.maxY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardCoversBar = false
        }
        // After the bar inset, so the panel sits directly on the keyboard rather than above the bar.
        .overlay {
            if isSearching {
                SearchSheet(url: store.isComposingNewTab ? nil : store.activeTab?.url,
                            isFocused: $searchFocused, onDismiss: dismissSearch,
                            dimsPage: store.activeTab?.url != nil,
                            // Not from a panel still animating out after a dismiss.
                            onPanelTopChange: { if isSearching { searchPanelTop = $0 } })
                    // Fresh text per tab. Not per intent: the panel's own Edit row switches from composing
                    // a new tab to editing this one, and must keep the field (and its focus) in place.
                    .id(store.state.activeTabID?.uuidString ?? "none")
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3), value: isSearching)
        .fullScreenCover(isPresented: $showSwitcher, onDismiss: switcherDidDismiss) {
            TabSwitcherView()
                // Keeps the browser in the window under the switcher (it draws its own background), so
                // a tab opened from a card has drawn its page by the time the card hands over to it.
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showActions, onDismiss: actionsDidDismiss) {
            ActionsSheet(session: store.activeSession, url: store.activeTab?.url, showSearch: {
                // Not deferred to `actionsDidDismiss`: that runs a second or more after the sheet
                // has gone. The field takes focus while the sheet slides away, since nothing
                // is left for the sheet to restore (see `presentActions`).
                showActions = false
                presentSearch()
            })
        }
        .alert("Couldn't read saved tabs.", isPresented: loadFailurePresented) {
            Button("Start Fresh") { store.startFresh() }
        } message: {
            if let name = store.loadFailure?.keptCopyName {
                Text("A copy was kept at \(name).")
            } else {
                Text("No copy could be kept. Starting fresh replaces them.")
            }
        }
        .alert("Tabs Are Stored Outside the App Group", isPresented: storageWarningPresented) {
            Button("OK") { store.dismissStorageFallbackWarning() }
        } message: {
            Text("Cormorant's shared container is unavailable, so the share extension can't send links. Reinstall the app to fix this.")
        }
        .onChange(of: store.isLoaded) {
            // A URL handed in at cold launch is usually the active tab by the time `isLoaded` flips,
            // but `onOpenURL` can land just after. With no tab yet, give it a moment so the panel and
            // keyboard never flash over the page (no interstitials for a default browser);
            // `searchIfBlank` re-checks, so a tab that arrived meanwhile wins.
            if store.activeTab != nil {
                searchIfBlank()
            } else {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    searchIfBlank()
                }
            }
        }
        // The alerts take focus; the panel comes up once they're answered.
        .onChange(of: alertIsUp) { searchIfBlank() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { searchIfBlank() }
            // In case a hide never arrives. A keyboard still up on return reports its frame again.
            if phase == .background { keyboardCoversBar = false }
        }
        // Nothing is sampled or tracked while tinting is off; catch up when it comes back on.
        .onChange(of: store.settings.tintsChrome) {
            store.activeSession?.updatePageTopTracking()
            store.activeSession?.schedulePageColorsRefresh()
        }
        .onChange(of: store.addressFocusRequest) {
            // From the switcher's "+": present once the cover is gone, or focus can't land.
            if !showSwitcher { presentSearch() }
        }
        .onChange(of: store.state.activeTabID) { _, _ in
            // A tab opened from outside (share sheet, URL) must not leave the panel or sheet over the page.
            if store.activeTab?.url != nil {
                dismissSearch()
                // Settings, if stacked on the sheet, goes with it.
                showActions = false
            } else if showActions {
                // The last tab closed under the caret sheet: `actionsDidDismiss` brings the panel up.
                showActions = false
            } else if !showSwitcher {
                // The last tab closed (e.g. by the page's script): back to the empty state.
                searchIfBlank()
            }
        }
        // The keyboard going away (interactive scroll, hardware dismiss) closes the panel with it.
        .onChange(of: searchFocused) { wasFocused, focused in
            if wasFocused, !focused, isSearching { dismissSearch() }
        }
        #if DEBUG
        // `-openActions` launch argument presents the caret sheet once a page is active, for headless
        // simulator checks where nothing can tap the caret.
        .task(id: store.activeTab?.url) {
            guard ProcessInfo.processInfo.arguments.contains("-openActions"), store.activeTab?.url != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { presentActions() }
        }
        #endif
    }

    /// A tab a link opened closes when swiped back from its first page. Not while its history is still
    /// being restored: it would look like a first page.
    private func backSwipeClose(for session: TabSession) -> WebViewContainer.BackSwipeClose? {
        let tabID = session.tabID
        guard store.closesOnBackSwipe(tabID), !session.isRestoringHistory else { return nil }
        return .init(destinationSnapshot: { store.backSwipeSnapshot(for: tabID) },
                     close: { store.close(tabID) })
    }

    /// The site's color for the status-bar strip, or nil for the default.
    private var chromeTint: ChromeTint? { store.stripTint(in: colorScheme) }

    /// The tab's colors are from the appearance before; the strip waits for them rather than fading
    /// to the default and back.
    private var chromeTintIsStale: Bool {
        store.settings.tintsChrome && store.activeSession?.pageColorsAreStale(in: colorScheme) == true
    }

    /// Dismissed only by its action, which clears the failure.
    private var loadFailurePresented: Binding<Bool> {
        Binding(get: { store.loadFailure != nil }, set: { _ in })
    }

    /// Waits for the load-failure alert so the two never compete.
    private var storageWarningPresented: Binding<Bool> {
        Binding(get: { store.showsStorageFallbackWarning && store.isLoaded && store.loadFailure == nil },
                set: { _ in })
    }

    private var alertIsUp: Bool {
        store.loadFailure != nil || storageWarningPresented.wrappedValue
    }

    /// No tabs (or a tab that hasn't loaded anything): the launch screen's bird, same asset and size.
    /// At rest it's centered on the whole screen, exactly where the launch screen drew it. With the
    /// search panel up it centers in the space above the panel instead, shrinking if that's short.
    private var emptyState: some View {
        // A reader rather than padding: it takes exactly the space offered, so a panel reaching the top
        // of the screen (landscape, many rows) shrinks the mark to nothing instead of growing the view.
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let height = searchPanelTop.map { min(max(0, $0 - frame.minY), frame.height) } ?? frame.height
            Image(.cormorantMark)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 128, maxHeight: 128)
                .padding(8)
                .accessibilityHidden(true)
                .accessibilityIgnoresInvertColors()
                .frame(width: frame.width, height: height)
        }
        // Screen-centered like the launch screen until the panel has a position to sit above; then
        // below the status bar.
        .ignoresSafeArea(.container, edges: searchPanelTop == nil ? .all : .bottom)
        .background(Color(.launchBackground).ignoresSafeArea())
        .contentShape(.rect)
        .onTapGesture(perform: dismissSearch)
        // Keeps pace with the panel (which rides the keyboard) so the mark never trails under it.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3), value: searchPanelTop)
    }

    // MARK: Presentation

    private func presentSearch() {
        store.activeSession?.isBarCollapsed = false
        isSearching = true
        // Set in the same update that inserts the field, so the keyboard comes up with the panel.
        searchFocused = true
    }

    private func dismissSearch() {
        store.cancelComposing()
        searchFocused = false
        isSearching = false
        searchPanelTop = nil
    }

    private func presentActions() {
        dismissSearch()
        // As for the switcher: the dismissing sheet would hand first responder back to the web view
        // and take focus from the panel the host button opens. Leave nothing to restore.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        showActions = true
    }

    private func actionsDidDismiss() {
        store.activeSession?.runPendingAction()
        // The last tab may have closed while the sheet was up.
        searchIfBlank()
    }

    private func presentSwitcher() {
        dismissSearch()
        showActions = false
        // Dismissing, the cover restores the first responder it found here: the web view, once the
        // page has been tapped. That took focus from the panel New Tab had just opened, and losing
        // focus closes the panel, so New Tab did nothing. Leave nothing to restore.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        store.snapshotActiveTab()
        showSwitcher = true
    }

    /// With no page to show, the search field is always up (default-browser requirement).
    private func searchIfBlank() {
        guard store.isLoaded, !alertIsUp, !showSwitcher, !showActions,
              store.activeTab?.url == nil else { return }
        presentSearch()
    }

    private func switcherDidDismiss() {
        if store.isComposingNewTab { presentSearch() } else { searchIfBlank() }
    }
}

/// The strip behind the status bar, in the site's color with a status bar that reads on it.
///
/// A new tab's color cuts in with the tab (and a page's with a back or forward navigation that
/// restores it): fading would trail the page by most of a second. A change on the page itself
/// (a scroll past a banner, a theme-color update, the appearance) fades, through OKLab so red to
/// green doesn't pass through olive, and the status bar changes style halfway through.
private struct StatusBarStrip: View {
    let tint: ChromeTint?
    let tabID: UUID?
    let fades: Bool
    /// `tint` is being re-read for a new appearance; hold the current color until it arrives.
    let isStale: Bool
    let colorScheme: ColorScheme

    @State private var shown: StripPaint
    /// When the tab last changed. Changes soon after (its colors arriving as it's shown, or as the
    /// switcher's card grows into it) cut too, so the strip matches what the switcher showed.
    @State private var tabChangedAt = Date.distantPast

    init(tint: ChromeTint?, tabID: UUID?, fades: Bool, isStale: Bool, colorScheme: ColorScheme) {
        self.tint = tint
        self.tabID = tabID
        self.fades = fades
        self.isStale = isStale
        self.colorScheme = colorScheme
        _shown = State(initialValue: StripPaint(tint: tint, colorScheme: colorScheme))
    }

    private struct Target: Equatable {
        let tabID: UUID?
        let paint: StripPaint
        /// Part of the key so the arrival of the re-read colors is a change even if they equal the
        /// placeholder computed while stale.
        let isStale: Bool
    }

    var body: some View {
        let target = Target(tabID: tabID, paint: StripPaint(tint: tint, colorScheme: colorScheme),
                            isStale: isStale)
        StripFill(paint: shown)
            .ignoresSafeArea()
            .onChange(of: target) { old, new in
                if old.tabID == new.tabID, new.isStale { return }
                if old.tabID != new.tabID { tabChangedAt = .now }
                if old.tabID == new.tabID, fades, Date.now.timeIntervalSince(tabChangedAt) > 0.5 {
                    withAnimation(.easeOut(duration: 0.25)) { shown = new.paint }
                } else {
                    var cut = Transaction(animation: nil)
                    cut.disablesAnimations = true
                    withTransaction(cut) { shown = new.paint }
                }
            }
    }
}

/// What the strip draws: a color in OKLab, so animating it interpolates there, and the status-bar
/// style as a number that crosses 0.5 at the fade's midpoint.
private struct StripPaint: Equatable {
    var color: OKLab
    /// 0: dark status-bar text (light scheme); 1: light text (dark scheme).
    var statusBarStyle: Double
    /// The default strip, which leaves the status bar to the system once it's settled.
    var isDefault: Bool
    /// `statusBarStyle` for the system's own style in this appearance.
    var systemStatusBarStyle: Double

    init(tint: ChromeTint?, colorScheme: ColorScheme) {
        color = (tint?.background ?? .launchBackground(in: colorScheme)).oklab
        systemStatusBarStyle = colorScheme == .dark ? 1 : 0
        statusBarStyle = tint.map { $0.colorScheme == .dark ? 1 : 0 } ?? systemStatusBarStyle
        isDefault = tint == nil
    }
}

private struct StripFill: View, Animatable {
    var paint: StripPaint

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(AnimatablePair(paint.color.l, paint.color.a), AnimatablePair(paint.color.b, paint.statusBarStyle))
        }
        set {
            paint.color = OKLab(l: newValue.first.first, a: newValue.first.second, b: newValue.second.first)
            paint.statusBarStyle = newValue.second.second
        }
    }

    var body: some View {
        let fill = Color(paint.color.rgb)
        if #available(iOS 27, *) {
            // Back to the system's style only once the fade to the default has arrived there.
            let settled = paint.isDefault && paint.statusBarStyle == paint.systemStatusBarStyle
            let scheme: ColorScheme? = settled ? nil : (paint.statusBarStyle < 0.5 ? .light : .dark)
            fill.toolbarColorScheme(scheme, for: .statusBar)
        } else {
            fill
        }
    }
}
