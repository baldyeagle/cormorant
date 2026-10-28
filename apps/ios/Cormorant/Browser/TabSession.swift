import CormorantBlocking
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
    /// Chrome tint for the status-bar strip. Always nil in build one; a later build can fill it
    /// from `<meta name="theme-color">` (it also needs a matching status-bar style).
    private(set) var themeColor: Color?
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
    /// A link from the long-press menu, to open in a new tab (switched to unless `inBackground`).
    @ObservationIgnored var onOpenInNewTab: ((_ url: URL, _ inBackground: Bool) -> Void)?
    /// The page called `window.close()`.
    @ObservationIgnored var onClose: (() -> Void)?
    /// The long-press menu's page preview, while one is up. See `LinkContextMenu.swift`.
    @ObservationIgnored weak var linkPreview: LinkPreviewController?
    @ObservationIgnored var onProcessTerminated: (() -> Void)?

    @ObservationIgnored let blocking: BlockingService
    @ObservationIgnored private let contentController: WKUserContentController
    @ObservationIgnored private let coordinator = WebViewCoordinator()
    @ObservationIgnored private let pullToRefresh: PullToRefresh
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
    /// Asked of WebKit for every navigation in this tab. Per tab, not persisted.
    @ObservationIgnored private(set) var requestedContentMode: WKWebpagePreferences.ContentMode = .recommended
    @ObservationIgnored private var scrollTravel: CGFloat = 0

    /// Safari's page zoom steps.
    static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private static let collapseDistance: CGFloat = 24
    private static let crashReloadLimit = 3
    private static let crashReloadWindow: TimeInterval = 5 * 60
    /// Schemes WebKit loads itself. Anything else belongs to another app.
    static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]
    /// Never acted on from inside a page: our own scheme (pages must not drive the app) and local files.
    static let refusedSchemes: Set<String> = ["cormorant", "file"]

    /// - Parameter configuration: supplied by WebKit for `window.open`; the new view must be built from it.
    init(tabID: UUID, blocking: BlockingService, configuration supplied: WKWebViewConfiguration? = nil) {
        self.tabID = tabID
        self.blocking = blocking
        let configuration: WKWebViewConfiguration
        if let supplied {
            configuration = supplied
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.allowsInlineMediaPlayback = true
        }
        // Each tab gets its own controller so rules applied here never touch an opener's web view.
        contentController = WKUserContentController()
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        pullToRefresh = PullToRefresh(webView: webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        coordinator.session = self
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        pullToRefresh.onRefresh = { [weak self] in self?.reload() }
        observe()
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
        // Asked for while another tab's sheet was open; it must not fire on a later dismissal.
        pendingAction = nil
        if needsReload { recoverFromCrash() }
    }

    /// Call when another tab takes the screen.
    func didResignActiveTab() {
        pullToRefresh.cancel()
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
    }

    func pageDidFinishLoading() { onPageLoaded?() }
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
        guard let presenter = webView.alertPresenter else { return }
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
                    self?.onPageChange?(web.url, web.title ?? "")
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.onPageChange?(web.url, web.title ?? "") }
            },
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.scrollViewDidScroll(scrollView) }
            },
        ]
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
