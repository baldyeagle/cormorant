import CormorantBlocking
import CormorantCore
import Observation
import OSLog
import SwiftUI
import UIKit
import WebKit

/// One tab's live `WKWebView` plus the state the browser chrome renders from it.
@MainActor
@Observable
final class TabSession {
    /// A main-frame load that failed; the browser shows it in place of the page.
    struct LoadError: Equatable {
        let message: String
        let url: URL?
    }

    let tabID: UUID
    let webView: WKWebView

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    /// Set while the user scrolls down a page; the bottom bar shrinks to a strip.
    var isBarCollapsed = false
    /// What the page offers the status-bar strip. Settled: see `schedulePageColorsRefresh()`.
    private(set) var pageColors = PageColors()
    private(set) var loadError: LoadError?
    /// A main-frame response WebKit can't display (a download). Downloads come in build two.
    var blockedDownloadURL: URL?
    /// Work the actions sheet hands off to run once it has finished dismissing. See `runPendingAction()`.
    @ObservationIgnored var pendingAction: PendingAction?
    /// Current page zoom, one of `zoomSteps`. Per tab, not persisted.
    private(set) var pageZoom: CGFloat = 1
    /// The content mode the last committed main-frame navigation actually got.
    private(set) var effectiveContentMode: WKWebpagePreferences.ContentMode = .recommended
    /// Saved back/forward history (from eviction or the last launch) waiting to go back in.
    private(set) var pendingHistory: Any?
    /// Until the history is back in, `canGoBack` reads false.
    var isRestoringHistory: Bool { pendingHistory != nil }

    @ObservationIgnored var onPageChange: ((URL?, String) -> Void)?
    @ObservationIgnored var onPageLoaded: (() -> Void)?
    /// `window.open` / `target=_blank`: return a web view built from the configuration, or nil.
    @ObservationIgnored var onCreateWebView: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    /// A link from the long-press menu, to open in a new tab (switched to unless `inBackground`),
    /// adopting the menu's preview web view when there is a `handoff`. Returns false if no tab opened.
    @ObservationIgnored var onOpenInNewTab: ((_ url: URL, _ inBackground: Bool, _ handoff: LinkPreviewHandoff?) -> Bool)?
    /// The page called `window.close()`.
    @ObservationIgnored var onClose: (() -> Void)?
    /// The long-press menu's page preview, while one is up. See `LinkContextMenu.swift`.
    @ObservationIgnored weak var linkPreview: LinkPreviewController?
    @ObservationIgnored var onProcessTerminated: (() -> Void)?
    /// This tab is the one on screen. Off screen (including loading on the background stage), a page
    /// can't put up dialogs.
    @ObservationIgnored private(set) var isActiveTab = false
    /// Media is held while the tab loads unseen in the background; released when it's first shown.
    @ObservationIgnored private var isMediaSuspendedUntilShown = false

    @ObservationIgnored let blocking: BlockingService
    @ObservationIgnored private let contentController: WKUserContentController
    @ObservationIgnored private let coordinator = WebViewCoordinator()
    @ObservationIgnored private let pullToRefresh: PullToRefresh
    @ObservationIgnored private let pageTopTracker = PageTopTracker()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Host and lists version the current rules were applied for; nil until the first successful apply.
    @ObservationIgnored private var appliedHost: String?
    @ObservationIgnored private var appliedListsVersion: Int?
    /// Serializes rule applications so a slow one can't land after a newer one.
    @ObservationIgnored private var applyTask: Task<Int?, Never>?
    /// The web content process died while this tab wasn't on screen; reload when it is.
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var crashReloads: [Date] = []
    @ObservationIgnored private var lastRequestedURL: URL?
    @ObservationIgnored private var lastScrollY: CGFloat = 0
    @ObservationIgnored private var lastInsetTop: CGFloat = 0
    @ObservationIgnored private var hasCommittedPage = false
    @ObservationIgnored private var pageColorsTask: Task<Void, Never>?
    /// When the pending page-colors refresh runs; pushed back while things keep changing.
    @ObservationIgnored private var pageColorsDeadline: ContinuousClock.Instant?
    /// Bumped per refresh, so a slow snapshot can't land after a newer refresh.
    @ObservationIgnored private var pageColorsGeneration = 0
    /// The next colors read are a page's first (it was just committed, adopted or shown), so they cut
    /// in rather than fade. Held while the page loads: its first frames may be the old page or blank.
    @ObservationIgnored private var cutsNextPageColors = true
    @ObservationIgnored private var traitRegistration: (any UITraitChangeRegistration)?
    /// The link preview's card snapshot, for this tab's first colors (see `seedPageColors()`).
    @ObservationIgnored private var adoptedSnapshot: UIImage?
    /// The switcher's picture of this tab's page, for first colors when it has never been on screen
    /// (it loaded in the background).
    @ObservationIgnored var thumbnail: (() -> UIImage?)?
    /// A refresh was asked for at once (the tab was just shown); later requests don't put it off.
    @ObservationIgnored private var pageColorsUrgent = false
    /// The pending refresh may run while the page scrolls (the live estimate couldn't read the top).
    @ObservationIgnored private var pageColorsDuringScroll = false
    /// The page's script can't read its top (a picture, a gradient, a frame): while it scrolls, the top
    /// is followed with snapshots instead, a few a second.
    @ObservationIgnored private var pageTopUnreadable = false
    private static let unreadableTopInterval: Duration = .milliseconds(250)
    #if DEBUG
    /// The last color the page's script reported at its top and the strip took up, for UI tests
    /// (`UITestingProbes`): the snapshot at rest can't tell them whether the strip followed a scroll.
    @ObservationIgnored private(set) var lastLivePageTop: RGBColor?
    #endif
    /// The status-bar strip's color for whichever tab is on screen, for an animation that hands over to
    /// it (the link preview's card growing into its new tab).
    @ObservationIgnored var activeStripColor: ((UIUserInterfaceStyle) -> UIColor?)?
    /// Whether the strip uses page colors at all; nothing is sampled while it doesn't.
    @ObservationIgnored var tintsChrome: () -> Bool = { true }
    /// Asked of WebKit for every navigation in this tab. Per tab, not persisted.
    @ObservationIgnored private(set) var requestedContentMode: WKWebpagePreferences.ContentMode = .recommended
    @ObservationIgnored private var scrollTravel: CGFloat = 0

    static let pageColorsSettle: Duration = .milliseconds(150)
    /// Points of the page's top edge sampled for the strip (its first and last rows are compared, so a
    /// thin border along the top isn't taken for the page), and the sample's width in points.
    private static let topEdgeHeight: CGFloat = 12
    private static let topEdgeSampleWidth: CGFloat = 48

    /// Safari's page zoom steps.
    static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private static let collapseDistance: CGFloat = 24
    private static let crashReloadLimit = 3
    private static let crashReloadWindow: TimeInterval = 5 * 60
    /// Schemes WebKit loads itself. Anything else belongs to another app.
    static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]
    /// Never acted on from inside a page: our own scheme (pages must not drive the app) and local files.
    static let refusedSchemes: Set<String> = ["cormorant", "file"]

    /// A tab's web view configuration. Link previews are built from it too, so a preview's web view
    /// can become a tab (`init(tabID:blocking:adopting:)`) with nothing configured differently.
    /// Configuration-level settings, user scripts included, belong here; anything that needs the
    /// session (script message handlers) goes in `init(tabID:blocking:webView:contentController:)`.
    /// Each web view gets its own content controller, so rules applied to one never touch another.
    static func makeConfiguration() -> (WKWebViewConfiguration, WKUserContentController) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        return (configuration, contentController)
    }

    /// - Parameter configuration: supplied by WebKit for `window.open`; the new view must be built from it.
    convenience init(tabID: UUID, blocking: BlockingService, configuration supplied: WKWebViewConfiguration? = nil) {
        let configuration: WKWebViewConfiguration
        let contentController: WKUserContentController
        if let supplied {
            configuration = supplied
            contentController = WKUserContentController()
            configuration.userContentController = contentController
        } else {
            (configuration, contentController) = Self.makeConfiguration()
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.init(tabID: tabID, blocking: blocking, webView: webView, contentController: contentController)
    }

    /// A tab that takes over a link preview's web view, page and all (see `LinkPreviewHandoff`).
    convenience init(tabID: UUID, blocking: BlockingService, adopting handoff: LinkPreviewHandoff) {
        self.init(tabID: tabID, blocking: blocking, webView: handoff.webView, contentController: handoff.contentController)
        appliedHost = handoff.appliedHost
        appliedListsVersion = handoff.appliedListsVersion
        requestedContentMode = handoff.requestedContentMode
        effectiveContentMode = handoff.effectiveContentMode
        pageZoom = webView.pageZoom
        lastRequestedURL = handoff.requestedURL
        // The page loaded before this session observed it.
        pullToRefresh.pageDidChange(webView.url)
        // Suspended while it was a preview; a tab plays media under the usual rules.
        webView.setAllMediaPlaybackSuspended(false)
        // Already committed, so no commit will say so. Its colors come with it when it's shown: the
        // card's snapshot is the page as it is, top edge included (see `seedPageColors()`).
        hasCommittedPage = webView.url != nil
        adoptedSnapshot = handoff.card?.snapshot
        // Its page loaded before the script was installed.
        if hasCommittedPage { pageTopTracker.inject(into: webView) }
        cutsNextPageColors = true
        schedulePageColorsRefresh()
    }

    private init(tabID: UUID, blocking: BlockingService, webView: WKWebView, contentController: WKUserContentController) {
        self.tabID = tabID
        self.blocking = blocking
        self.webView = webView
        self.contentController = contentController
        pullToRefresh = PullToRefresh(webView: webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        coordinator.session = self
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        pullToRefresh.onRefresh = { [weak self] in self?.reload() }
        pageTopTracker.session = self
        pageTopTracker.install(in: contentController)
        observe()
        // The page's colors (and its media queries) follow the appearance; re-read them when it changes.
        traitRegistration = webView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (_: WKWebView, _: UITraitCollection) in
            self?.schedulePageColorsRefresh()
        }
    }

    /// Installs blocking rules, then performs the tab's first load: restoring saved back/forward
    /// history if there is any, else loading `url`.
    func start(loading url: URL?, restoring interactionState: Any? = nil) {
        let host = url?.host()?.lowercased()
        pendingHistory = interactionState
        // A reload after a content-process crash (which clears `webView.url`) needs it, history or not.
        lastRequestedURL = url
        Task {
            defer { pendingHistory = nil }
            await applyBlocking(host: host)
            guard webView.url == nil, !webView.isLoading else { return }
            if let interactionState {
                webView.interactionState = interactionState
            }
            // No history, or WebKit rejected it (saved by another WebKit version): just the page. Or
            // the tab moved on after its history was saved (the app was killed without going inactive):
            // its newer page goes on top.
            if let url, webView.backForwardList.currentItem?.url != url {
                load(url)
            }
        }
    }

    /// Installs already-compiled rules synchronously, for a web view WebKit is about to navigate itself.
    func installCachedBlocking(for url: URL?) {
        let host = url?.host()?.lowercased()
        let cached = blocking.cachedLists(for: host)
        contentController.removeAllContentRuleLists()
        for list in cached.lists { contentController.add(list) }
        appliedHost = host
        appliedListsVersion = cached.version
    }

    func load(_ url: URL) {
        lastRequestedURL = url
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { reload() }
    }

    // MARK: Page actions

    /// Something the actions sheet asked for that can only happen once the sheet is gone.
    enum PendingAction {
        /// The find navigator needs first responder, which the dismissing sheet still holds.
        case findOnPage
    }

    /// Call from the actions sheet's `onDismiss`. Runs and clears `pendingAction`.
    func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .findOnPage:
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    var canZoomIn: Bool { pageZoom < Self.zoomSteps[Self.zoomSteps.count - 1] - 0.001 }
    var canZoomOut: Bool { pageZoom > Self.zoomSteps[0] + 0.001 }

    func zoomIn() {
        if let next = Self.zoomSteps.first(where: { $0 > pageZoom + 0.001 }) { setPageZoom(next) }
    }

    func zoomOut() {
        if let previous = Self.zoomSteps.last(where: { $0 < pageZoom - 0.001 }) { setPageZoom(previous) }
    }

    func resetZoom() { setPageZoom(1) }

    private func setPageZoom(_ zoom: CGFloat) {
        pageZoom = zoom
        webView.pageZoom = zoom
    }

    /// The page is showing its desktop layout (as committed, not just requested).
    var isDesktopSite: Bool { effectiveContentMode == .desktop }

    /// Asks for the other layout for the rest of this tab's life and reloads.
    /// Like Safari, goes back to the URL the page was first requested at, so a user-agent
    /// redirect (`example.com` to `m.example.com`) is undone rather than reloaded.
    /// Only a change of site counts: other redirects (http to https, adding `www.`) and `replaceState`
    /// would load a stale URL or add a duplicate history entry, so those just reload.
    func toggleDesktopSite() {
        requestedContentMode = isDesktopSite ? .mobile : .desktop
        let site = { (url: URL?) in url?.host().map(BlockingPreferences.normalize(host:)) }
        if let initial = webView.backForwardList.currentItem?.initialURL, site(initial) != site(webView.url) {
            load(initial)
        } else {
            reload()
        }
    }

    /// Zoom and requested layout, carried over to a rebuilt web view or a popup from this tab.
    struct ViewSettings {
        let pageZoom: CGFloat
        let contentMode: WKWebpagePreferences.ContentMode
    }

    var viewSettings: ViewSettings {
        ViewSettings(pageZoom: pageZoom, contentMode: requestedContentMode)
    }

    /// Call before the first navigation, so it already gets the requested layout.
    func apply(_ settings: ViewSettings) {
        requestedContentMode = settings.contentMode
        setPageZoom(settings.pageZoom)
    }

    /// Re-applies rules for the current host after a preferences or list change.
    func reapplyBlocking(reload: Bool) {
        let host = webView.url?.host()?.lowercased()
        Task {
            await applyBlocking(host: host)
            if reload { self.reload() }
        }
    }

    /// Clears the error view and loads the failed URL again.
    func retry() {
        let url = loadError?.url
        loadError = nil
        // A page restored from history that failed to come back is reloaded in place; loading it
        // would add a second back entry for it.
        if let url, webView.backForwardList.currentItem?.url != url { load(url) } else { reload() }
    }

    /// Call when this tab becomes the one on screen.
    func didBecomeActiveTab() {
        isActiveTab = true
        if isMediaSuspendedUntilShown {
            isMediaSuspendedUntilShown = false
            webView.setAllMediaPlaybackSuspended(false)
        }
        // Asked for while another tab's sheet was open; it must not fire on a later dismissal.
        pendingAction = nil
        if needsReload { recoverFromCrash() }
        // Colors with the tab: its own if they're for the page it's on now, else the page's kept ones,
        // else what WebKit already knows (the top edge comes with the sample, which runs at once).
        seedPageColors()
        schedulePageColorsRefresh(after: .zero)
        updatePageTopTracking()
    }

    /// For a tab loading in the background: nothing plays (or is heard) until it's shown.
    func suspendMediaUntilShown() {
        guard !isActiveTab, !isMediaSuspendedUntilShown else { return }
        isMediaSuspendedUntilShown = true
        webView.setAllMediaPlaybackSuspended(true)
    }

    /// Call when another tab takes the screen.
    func didResignActiveTab() {
        isActiveTab = false
        pullToRefresh.cancel()
        updatePageTopTracking()
    }

    // MARK: Called by the coordinator

    func policy(for action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        if Self.refusedSchemes.contains(scheme) {
            Logger.app.notice("Cancelled in-page navigation to \(scheme, privacy: .public): URL")
            return .cancel
        }
        if !Self.webSchemes.contains(scheme) {
            handleExternal(url, action: action)
            return .cancel
        }
        guard action.targetFrame?.isMainFrame == true else { return .allow }
        let host = url.host()?.lowercased()
        // A re-apply may be in flight (toggle, list change) and may have been started with the
        // previous page's host; wait for it, then re-check against this navigation's host.
        _ = await applyTask?.value
        if host != appliedHost || appliedListsVersion != blocking.listsVersion {
            await applyBlocking(host: host)
        }
        return .allow
    }

    func policy(for response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        guard !response.canShowMIMEType else { return .allow }
        if response.isForMainFrame { blockedDownloadURL = response.response.url }
        return .cancel
    }

    func createWebView(configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView? {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
           !Self.webSchemes.contains(scheme) {
            if !Self.refusedSchemes.contains(scheme) { handleExternal(url, action: action) }
            return nil
        }
        return onCreateWebView?(configuration, action)
    }

    func navigationDidStart() {
        loadError = nil
        blockedDownloadURL = nil
    }

    func navigationDidFail(_ error: any Error) {
        let error = error as NSError
        // Cancelled (a newer navigation replaced this one) and "frame load interrupted" (we cancelled
        // it ourselves: downloads, other apps) aren't failures the user needs to see.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", [102, 204].contains(error.code) { return }
        let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url ?? lastRequestedURL
        loadError = LoadError(message: error.localizedDescription, url: url)
    }

    func navigationDidCommit(_ navigation: WKNavigation) {
        effectiveContentMode = navigation.effectiveContentMode
        hasCommittedPage = true
        // A new document; its script will say whether it can read the top. One restored from the
        // back/forward cache asks again itself; this covers it too.
        pageTopUnreadable = false
        updatePageTopTracking()
        // A refresh still waiting on a snapshot was for the page before; it mustn't land on this one.
        pageColorsGeneration += 1
        // Back or forward to a page seen before: its colors come with it, not a beat later.
        if let item = webView.backForwardList.currentItem, item !== pageColors.item, var colors = item.pageColors {
            colors.item = item
            colors.fades = false
            pageColors = colors
        }
        cutsNextPageColors = true
        schedulePageColorsRefresh()
        // And once more after the page has had time to paint past its first frames.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.schedulePageColorsRefresh()
        }
    }

    func pageDidFinishLoading() {
        onPageLoaded?()
        schedulePageColorsRefresh()
    }
    func pageDidRequestClose() { onClose?() }

    func webContentProcessDidTerminate() {
        Logger.app.error("Web content process terminated for tab \(self.tabID, privacy: .public)")
        needsReload = true
        onProcessTerminated?()
    }

    /// Reloads after a content-process crash, at most `crashReloadLimit` times per `crashReloadWindow`;
    /// past that the error view offers a manual retry instead of looping.
    func recoverFromCrash() {
        guard needsReload else { return }
        needsReload = false
        let now = Date.now
        crashReloads.removeAll { now.timeIntervalSince($0) > Self.crashReloadWindow }
        guard crashReloads.count < Self.crashReloadLimit else {
            loadError = LoadError(message: "This page stopped working several times.", url: webView.url ?? lastRequestedURL)
            return
        }
        crashReloads.append(now)
        reload()
    }

    // MARK: Private

    private func reload() {
        // After a content-process crash `url` is nil but the history survives: reloading its current
        // item keeps the tab where it was, where loading `lastRequestedURL` would add an entry.
        if webView.url != nil || webView.backForwardList.currentItem != nil {
            webView.reload()
        } else if let lastRequestedURL {
            load(lastRequestedURL)
        }
    }

    @discardableResult
    private func applyBlocking(host: String?) async -> Bool {
        let previous = applyTask
        let task = Task { [blocking, contentController] in
            _ = await previous?.value
            return await blocking.apply(to: contentController, host: host)
        }
        applyTask = task
        guard let version = await task.value else { return false }
        appliedHost = host
        appliedListsVersion = version
        return true
    }

    /// Other apps only open from a tap on a link, and only after the user confirms.
    private func handleExternal(_ url: URL, action: WKNavigationAction) {
        guard action.navigationType == .linkActivated else {
            Logger.app.notice("Cancelled non-user navigation to \(url.scheme ?? "", privacy: .public): URL")
            return
        }
        confirmOpeningInOtherApp(url)
    }

    /// Asks before handing `url` to the app that owns its scheme.
    func confirmOpeningInOtherApp(_ url: URL) {
        guard isActiveTab, let presenter = webView.alertPresenter else { return }
        let alert = UIAlertController(title: "Open in \(Self.appName(for: url))?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in
            UIApplication.shared.open(url)
        })
        presenter.present(alert, animated: true)
    }

    private static func appName(for url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "mailto": "Mail"
        case "tel": "Phone"
        case "sms": "Messages"
        case "facetime", "facetime-audio": "FaceTime"
        case "itms-apps", "itms-appss": "App Store"
        case "maps": "Maps"
        case let scheme?: url.host().flatMap { $0.isEmpty ? nil : "\(scheme) (\($0))" } ?? scheme
        case nil: "another app"
        }
    }

    private func observe() {
        // WKWebView and UIScrollView post these KVO changes on the main thread.
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.isLoading = web.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.progress = web.estimatedProgress }
            },
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    self?.setBarCollapsed(false)
                    self?.pullToRefresh.pageDidChange(web.url)
                    // Also same-document navigations (pushState), which commit nothing.
                    self?.schedulePageColorsRefresh()
                    self?.onPageChange?(web.url, web.title ?? "")
                }
            },
            webView.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedulePageColorsRefresh() }
            },
            webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedulePageColorsRefresh() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.onPageChange?(web.url, web.title ?? "") }
            },
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    self?.scrollViewDidScroll(scrollView)
                    self?.pageDidScroll()
                }
            },
        ]
    }

    /// Re-reads the page's colors once nothing has changed for `pageColorsSettle`: a scroll has come
    /// to rest, a load has settled. Around a first load or a crash reload WebKit passes through
    /// placeholders (no theme color, a white under-page color) for ~100 ms before the page's own;
    /// adopting those would flash the strip and flip the status bar. Cheap to call per scroll frame:
    /// it only pushes a deadline back.
    func schedulePageColorsRefresh(after settle: Duration = pageColorsSettle, duringScroll: Bool = false) {
        if duringScroll { pageColorsDuringScroll = true }
        let deadline = ContinuousClock.now + settle
        if settle < Self.pageColorsSettle {
            pageColorsUrgent = true
            pageColorsDeadline = min(deadline, pageColorsDeadline ?? deadline)
        } else if !pageColorsUrgent {
            pageColorsDeadline = deadline
        }
        guard pageColorsTask == nil else { return }
        // One task at a time, so at most one snapshot is ever in flight; a call during one runs
        // another refresh after it.
        pageColorsTask = Task {
            while let deadline = pageColorsDeadline {
                if deadline > .now {
                    // In short steps, so a deadline brought forward (the tab was shown) is met.
                    try? await Task.sleep(until: min(deadline, .now + .milliseconds(30)))
                    continue
                }
                // Never mid-scroll, even a drag held still: only once the page is at rest.
                let scrollView = webView.scrollView
                if !pageColorsDuringScroll, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                    pageColorsDeadline = .now + Self.pageColorsSettle
                    continue
                }
                pageColorsDeadline = nil
                pageColorsUrgent = false
                pageColorsDuringScroll = false
                await refreshPageColors()
            }
            pageColorsTask = nil
        }
    }

    // MARK: Live tracking while scrolling (see `PageTopTracker`)

    /// The page's script follows the top while it scrolls: only for the tab on screen, with tinting on.
    var tracksPageTopLive: Bool { isActiveTab && tintsChrome() }

    /// Call when `tracksPageTopLive` may have changed.
    func updatePageTopTracking() {
        pageTopTracker.setActive(tracksPageTopLive, in: webView)
    }

    /// The page's top edge changes as it scrolls: its script follows it, and a snapshot confirms it once
    /// the page rests. Where the script can't read the top, snapshots follow it instead, a few a second.
    private func pageDidScroll() {
        if pageTopUnreadable, tracksPageTopLive {
            schedulePageColorsRefresh(after: Self.unreadableTopInterval, duringScroll: true)
        } else {
            schedulePageColorsRefresh()
        }
    }

    /// The page's script read a new color at its top: `[r, g, b, a]`, alpha below 1 where the canvas
    /// shows through, or nil when it couldn't tell (a picture, a frame, a mix). Shown at once, with the
    /// in-place fade; the snapshot once scrolling rests confirms or corrects it.
    func pageTopDidChange(_ components: [Double]?, isBaseline: Bool = false) {
        let scrollView = webView.scrollView
        guard tracksPageTopLive, hasCommittedPage,
              // Pulled down for a refresh: the top shows the overscroll area, not the page.
              scrollView.contentOffset.y + scrollView.adjustedContentInset.top >= -1,
              scrollView.refreshControl?.isRefreshing != true else { return }
        pageTopUnreadable = components == nil
        // Where tracking started (the tab was shown, the page loaded): the snapshot has that covered.
        guard !isBaseline else { return }
        guard let components else {
            // Only a snapshot can say; take one now rather than when the scrolling stops.
            schedulePageColorsRefresh(after: .zero, duringScroll: true)
            return
        }
        let item = webView.backForwardList.currentItem
        let style = webView.traitCollection.userInterfaceStyle
        var color = RGBColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        if color.alpha < 1 {
            // What shows through is the canvas, which WebKit draws in the under-page color.
            let canvas = RGBColor(webView.underPageBackgroundColor, in: webView.traitCollection)
                ?? RGBColor(UIColor(resource: .launchBackground), in: webView.traitCollection) ?? .white
            color = color.composited(over: canvas)
        }
        guard let topEdge = TopEdgeSample(pixels: [color]) else { return }
        #if DEBUG
        lastLivePageTop = color
        #endif
        var colors = pageColors
        colors.topEdge = topEdge
        colors.item = item
        colors.style = style
        colors.fades = !cutsNextPageColors
        // Newer than any snapshot still in flight, which mustn't land on top of it.
        pageColorsGeneration += 1
        if colors != pageColors { pageColors = colors }
        // The arbiter: a snapshot once it all comes to rest.
        schedulePageColorsRefresh()
    }

    /// Brings `pageColors` in line with the page on screen without waiting for a sample: the item's
    /// kept colors, or WebKit's theme and under-page colors, read now in the current appearance.
    private func seedPageColors() {
        let item = webView.backForwardList.currentItem
        let style = webView.traitCollection.userInterfaceStyle
        let snapshot = adoptedSnapshot
        adoptedSnapshot = nil
        guard item !== pageColors.item || style != pageColors.style else { return }
        if var colors = item?.pageColors, colors.style == style {
            colors.item = item
            colors.fades = false
            pageColors = colors
        } else {
            // A picture of the page as it is, if there is one: the link preview's card (the page at
            // this tab's size), or the switcher's thumbnail of a tab that has never been on screen (it
            // loaded in the background). The same top edge a live sample would find, without one.
            var topEdge: TopEdgeSample?
            let width = webView.bounds.width
            if tintsChrome(), hasCommittedPage, width > 0 {
                if let snapshot {
                    topEdge = snapshot.topEdgeSample(height: Self.topEdgeHeight * snapshot.size.width / width,
                                                     width: Self.topEdgeSampleWidth)
                } else if pageColors.item == nil, let thumbnail = thumbnail?() {
                    topEdge = thumbnail.topEdgeSample(height: Self.topEdgeHeight * thumbnail.size.width / width,
                                                      width: Self.topEdgeSampleWidth)
                }
            }
            pageColors = PageColors(theme: webView.themeColor,
                                    underPage: hasCommittedPage ? webView.underPageBackgroundColor : nil,
                                    topEdge: topEdge, item: item, style: style, fades: false)
            // Its first colors are in; a page still loading may yet paint differently, and cuts again.
            cutsNextPageColors = webView.isLoading
        }
    }

    private func refreshPageColors() async {
        // Only the tab on screen: one loading on the background stage, or off screen, doesn't drive the
        // strip and isn't worth a snapshot (and its appearance may not be the window's). It's refreshed
        // when it's shown.
        guard isActiveTab, webView.window != nil else { return }
        pageColorsGeneration += 1
        let generation = pageColorsGeneration
        // All read together, before the snapshot, so they describe one page in one appearance.
        let item = webView.backForwardList.currentItem
        let theme = webView.themeColor
        let underPage = hasCommittedPage ? webView.underPageBackgroundColor : nil
        let style = webView.traitCollection.userInterfaceStyle
        let sample = await sampleTopEdge()
        // A newer refresh, or a navigation, came along while this one waited on the snapshot.
        guard generation == pageColorsGeneration, webView.backForwardList.currentItem === item,
              webView.traitCollection.userInterfaceStyle == style else { return }
        // No sample (pulled past the top, mid-refresh): keep this page's last one if it's from this
        // appearance, never another page's. With tinting off, none: it would be stale when turned on.
        let keeps = tintsChrome() && item === pageColors.item && style == pageColors.style
        let topEdge = sample ?? (keeps ? pageColors.topEdge : nil)
        // A page's first colors cut in, as the page did (after a relaunch, in a rebuilt or adopted tab,
        // going back to a page whose colors weren't kept); later changes on the page fade, including
        // same-document navigations (pushState, fragments).
        let colors = PageColors(theme: theme, underPage: underPage, topEdge: topEdge, item: item, style: style,
                                fades: !cutsNextPageColors)
        if !webView.isLoading { cutsNextPageColors = false }
        if colors != pageColors { pageColors = colors }
        // Kept on the item itself (without a reference back to it), so they go when WebKit drops it.
        var stored = colors
        stored.item = nil
        item?.pageColors = stored
    }

    /// A thin row along the top of what's on screen, for the strip to continue. Nil when there's
    /// nothing meaningful to sample: no page, not on screen, or pulled down past the top (the edge
    /// then shows the overscroll area, or the refresh spinner).
    private func sampleTopEdge() async -> TopEdgeSample? {
        let scrollView = webView.scrollView
        // A point of slack: a bounce can settle a fraction above the top.
        guard tintsChrome(), hasCommittedPage, webView.window != nil, webView.bounds.width > 0,
              scrollView.contentOffset.y + scrollView.adjustedContentInset.top >= -1,
              scrollView.refreshControl?.isRefreshing != true else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: Self.topEdgeHeight)
        // Wide enough that the image has at least 4 pixel rows on any width of view (a wide iPad's
        // 12 pt would otherwise round to one row, or none).
        let scale = webView.window?.screen.scale ?? 3
        let width = max(Self.topEdgeSampleWidth, (webView.bounds.width * 4 / (Self.topEdgeHeight * scale)).rounded(.up))
        configuration.snapshotWidth = NSNumber(value: Double(width))
        // What's on screen now, not the last frame before the page painted.
        configuration.afterScreenUpdates = true
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        let rows = image.sRGBRows()
        guard let edge = rows.first, let below = rows.last else { return nil }
        return TopEdgeSample(rows: [edge, below])
    }

    /// Collapses the bar after a short scroll down, expands it after a short scroll up or at the top.
    private func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let insetTop = scrollView.adjustedContentInset.top
        let y = scrollView.contentOffset.y + insetTop
        // The pull-to-refresh spinner adds and removes top inset, which shifts `y` with no scrolling;
        // that shift mustn't count as travel (a spinner ending mid-scroll would expand the bar).
        let delta = insetTop == lastInsetTop ? y - lastScrollY : 0
        lastScrollY = y
        lastInsetTop = insetTop
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if y <= 0 {
            setBarCollapsed(false)
            return
        }
        // At the end of the scroll range, offset changes come from bounce and inset clamping, not
        // from the user's intent; leave the bar as it is.
        let maxY = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        if y >= maxY - 1 {
            scrollTravel = 0
            return
        }
        if (delta > 0) != (scrollTravel > 0) { scrollTravel = 0 }
        scrollTravel += delta
        if scrollTravel > Self.collapseDistance {
            setBarCollapsed(true)
        } else if scrollTravel < -Self.collapseDistance {
            setBarCollapsed(false)
        }
    }

    func setBarCollapsed(_ collapsed: Bool) {
        guard isBarCollapsed != collapsed else { return }
        withAnimation(.snappy(duration: 0.25)) { isBarCollapsed = collapsed }
    }
}
