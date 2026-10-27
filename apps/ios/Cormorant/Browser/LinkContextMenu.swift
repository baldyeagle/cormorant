import UIKit
import WebKit

/// The long-press menu for links: open here, in a new tab or a background tab, copy, share, with a
/// live preview of http(s) pages. Tapping the preview opens the link in a new tab, the card growing
/// into the page.
///
/// The preview is built like a tab's web view, laid out at the tab's size, so once its page has
/// committed, opening the link in a new tab (from the menu or by tapping the preview) adopts the
/// preview's web view instead of loading the page again (`LinkPreviewHandoff`).
///
/// Without a `WKUIDelegate` menu, WebKit hands http(s) links to the system's DataDetectors link
/// menu, whose Open Link and preview tap open the URL in the default browser, not in this tab.
extension TabSession {
    /// What a long-pressed link can do.
    enum LinkKind {
        /// http(s): this tab or a new one, with a preview.
        case page
        /// Belongs to another app; opening asks first, as a tap on the link does.
        case otherApp
        /// Copy and share only: our own scheme and local files (never opened from a page), and
        /// about:, data: and blob:, which a tap can't open top-level either (and a data: URL could
        /// be megabytes in saved tabs).
        case copyOnly
        /// `javascript:` only means something as a click in its page; no menu.
        case script
    }

    static func linkKind(for url: URL) -> LinkKind {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https": return .page
        case "javascript": return .script
        case _ where refusedSchemes.contains(scheme) || webSchemes.contains(scheme) || scheme.isEmpty: return .copyOnly
        default: return .otherApp
        }
    }

    /// Nil only for `javascript:` links, which then get no menu. (Nil for an http(s) link would bring
    /// back the system menu.)
    func linkMenuConfiguration(for url: URL) -> UIContextMenuConfiguration? {
        let kind = Self.linkKind(for: url)
        guard kind != .script else { return nil }
        let preview: UIContextMenuContentPreviewProvider? = kind == .page
            ? { [weak self] in self?.makeLinkPreview(for: url) }
            : nil
        return UIContextMenuConfiguration(identifier: url as NSURL, previewProvider: preview) { [weak self] _ in
            self?.linkMenu(for: url, kind: kind)
        }
    }

    /// The preview was tapped: open the link in a new tab, taking the preview's page with it. The
    /// system pops the (frozen) preview away while the live page grows from the card's frame to fill
    /// the screen over this one (`WebViewContainer.ContainerView.expand`).
    func commitLinkPreview(_ url: URL?, animator: any UIContextMenuInteractionCommitAnimating) {
        guard let url, Self.linkKind(for: url) == .page else { return }
        animator.preferredCommitStyle = .pop
        let handoff = takeHandoff(for: url, freezingPreview: true)
        // Read before the switch: this tab's web view leaves the container once the new one lands.
        let container = webView.superview as? WebViewContainer.ContainerView
        guard onOpenInNewTab?(url, false, handoff) == true else { return }
        if let handoff, let card = handoff.card, let container {
            container.expand(handoff.webView, from: card)
        }
    }

    /// The menu for `url` closed (dismissed, an action chosen, or the preview tapped). Its end can
    /// arrive after the next menu's preview exists; that one is left running.
    func linkMenuDidEnd(for url: URL?) {
        guard let preview = linkPreview, preview.url == url else { return }
        preview.stop()
        linkPreview = nil
    }

    /// Open Link: loads in this tab, or asks before handing it to another app.
    func openLink(_ url: URL) {
        switch Self.linkKind(for: url) {
        case .page: load(url)
        case .otherApp: confirmOpeningInOtherApp(url)
        case .copyOnly, .script: break
        }
    }

    // MARK: Private

    /// WebKit's suggested actions are left out, its image ones (Save to Photos, which would need a
    /// photo-library purpose string) included: linked images get the link menu, as they did before.
    private func linkMenu(for url: URL, kind: LinkKind) -> UIMenu {
        var open: [UIMenuElement] = []
        if kind != .copyOnly {
            open.append(UIAction(title: "Open Link", image: UIImage(systemName: "arrow.up.right")) { [weak self] _ in
                self?.openLink(url)
            })
        }
        if kind == .page {
            open.append(UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.openInNewTab(url, inBackground: false)
            })
            open.append(UIAction(title: "Open in Background Tab", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                self?.openInBackgroundTab(url)
            })
        }
        let pass: [UIMenuElement] = [
            UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = url
            },
            UIAction(title: "Share Link", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(url)
            },
        ]
        // The address, since a preview can take a moment and other links have none. Capped: a data:
        // URL can be any length, and VoiceOver reads all of it.
        let address = url.absoluteString
        let title = address.count > 200 ? address.prefix(200) + "…" : address
        return UIMenu(title: title, children: [
            UIMenu(options: .displayInline, children: open),
            UIMenu(options: .displayInline, children: pass),
        ].filter { !$0.children.isEmpty })
    }

    /// Menu actions run once the menu (and its preview) has gone, before WebKit reports the menu
    /// ended, so the preview's web view is still there to take.
    @discardableResult
    private func openInNewTab(_ url: URL, inBackground: Bool) -> Bool {
        onOpenInNewTab?(url, inBackground, takeHandoff(for: url, freezingPreview: false)) == true
    }

    /// The preview's web view for `url`, if its page can become a tab. See `LinkPreviewController.handoff`.
    private func takeHandoff(for url: URL, freezingPreview: Bool) -> LinkPreviewHandoff? {
        guard let preview = linkPreview, preview.url == url else { return nil }
        return preview.handoff(freezing: freezingPreview)
    }

    /// The current page stays. The bar expands so the badge can be seen counting up, with a
    /// VoiceOver announcement (queued, so the menu closing doesn't cut it off).
    private func openInBackgroundTab(_ url: URL) {
        guard openInNewTab(url, inBackground: true) else { return }
        setBarCollapsed(false)
        let announcement = NSAttributedString(string: "Opened in background tab",
                                              attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func share(_ url: URL) {
        guard let presenter = webView.alertPresenter else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
        }
        presenter.present(controller, animated: true)
    }

    private func makeLinkPreview(for url: URL) -> UIViewController {
        linkPreview?.stop()
        let preview = LinkPreviewController(url: url, blocking: blocking, settings: viewSettings,
                                            layout: PageLayout(of: webView))
        // Small: about half the screen, full menu width.
        if let bounds = webView.window?.bounds {
            preview.preferredContentSize = CGSize(width: bounds.width, height: (bounds.height * 0.5).rounded())
        }
        linkPreview = preview
        return preview
    }
}

/// A link preview's web view on its way to becoming a tab, with what the tab needs to carry on from
/// where the preview got to.
struct LinkPreviewHandoff {
    /// Where the preview's card was on screen, for the tab to grow from.
    struct Card {
        /// In window coordinates.
        let frame: CGRect
        let cornerRadius: CGFloat
        /// The page's scale in the card: it is laid out at the tab's size and shrunk to fit.
        let scale: CGFloat
    }

    let webView: WKWebView
    let contentController: WKUserContentController
    let appliedHost: String?
    let appliedListsVersion: Int?
    let requestedContentMode: WKWebpagePreferences.ContentMode
    let effectiveContentMode: WKWebpagePreferences.ContentMode
    let requestedURL: URL
    /// Nil unless the preview was on screen (a tapped preview; menu actions run after it has gone).
    let card: Card?
}

/// A link's page, shown under its long-press menu. Built from a tab's configuration and laid out at
/// the tab's size (scaled to fit the card), with the opener's zoom and desktop/mobile choice, so the
/// page can become a new tab as it is (`handoff(freezing:)`).
///
/// Until then it is not a tab: its own history, nothing reported to tab or saved state, no windows,
/// other apps or dialogs (no UI delegate), media suspended, and stopped when the menu closes. Its
/// rules match a tab's on the same host.
final class LinkPreviewController: UIViewController, WKNavigationDelegate {
    let url: URL
    private let blocking: BlockingService
    private let settings: TabSession.ViewSettings
    private let layout: PageLayout
    private let contentController: WKUserContentController
    private let webView: WKWebView
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Host and lists version the current rules were applied for.
    private var appliedHost: String?
    private var appliedListsVersion: Int?
    private var effectiveContentMode: WKWebpagePreferences.ContentMode = .recommended
    private var isStopped = false
    private var hasCommitted = false
    /// A load failed or was cut off, or the content process died: the page isn't what a tab would show.
    private var isBroken = false
    private var isHandedOff = false
    /// Main-frame navigations waiting on a policy decision (and maybe a rules update). Their rules
    /// could land on the content controller after a handoff, behind the tab's back.
    private var pendingMainFrameDecisions = 0
    /// Where the card rested on screen once presented, in window coordinates. By the time a tap
    /// commits, UIKit has begun moving and scaling the card, so its frame then isn't where it was seen.
    private var restingFrame: CGRect?

    init(url: URL, blocking: BlockingService, settings: TabSession.ViewSettings, layout: PageLayout) {
        self.url = url
        self.blocking = blocking
        self.settings = settings
        self.layout = layout
        let (configuration, contentController) = TabSession.makeConfiguration()
        self.contentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        webView.pageZoom = settings.pageZoom
        layout.apply(to: webView)
        // Nothing plays from a preview. Resumed if it becomes a tab, where the usual rules apply.
        webView.setAllMediaPlaybackSuspended(true)
        // Rules first, as for a tab's first load.
        let host = url.host()?.lowercased()
        Task { [weak self] in
            guard let self else { return }
            await applyBlocking(host: host)
            guard !isStopped else { return }
            webView.load(URLRequest(url: url))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // A container, so nothing WebKit adds to its own view can cover the spinner.
        let container = UIView()
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        container.addSubview(webView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isHandedOff else { return }
        // The page keeps the tab's layout; the card shows the top of it, shrunk to the card's width.
        let s = scale
        webView.bounds = CGRect(origin: .zero, size: pageSize)
        webView.transform = CGAffineTransform(scaleX: s, y: s)
        webView.center = CGPoint(x: pageSize.width * s / 2, y: pageSize.height * s / 2)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window { restingFrame = view.convert(view.bounds, to: window) }
    }

    /// Stops loading for good. The view itself goes when UIKit releases the preview.
    func stop() {
        guard !isHandedOff else { return }
        isStopped = true
        if webView.isLoading { isBroken = true }
        webView.stopLoading()
    }

    /// Gives up the web view so a tab can adopt it, or nil if the page isn't one a tab should take as
    /// it is: nothing committed yet, a failed, interrupted or crashed load, a page that moved off
    /// http(s), or one that already has back history (a tab's must start at this page). A page still
    /// loading its subresources is fine; the tab carries on with the load.
    ///
    /// - Parameter freezing: leave a snapshot in the card, for a preview still on screen.
    func handoff(freezing: Bool) -> LinkPreviewHandoff? {
        guard !isHandedOff, !isStopped, hasCommitted, !isBroken, pendingMainFrameDecisions == 0,
              let current = webView.url,
              TabSession.linkKind(for: current) == .page, webView.backForwardList.backList.isEmpty
        else { return nil }
        var card: LinkPreviewHandoff.Card?
        if freezing, let window = view.window {
            card = LinkPreviewHandoff.Card(frame: restingFrame ?? view.convert(view.bounds, to: window),
                                           cornerRadius: platterCornerRadius, scale: scale)
            if let frozen = webView.snapshotView(afterScreenUpdates: false) {
                frozen.bounds = webView.bounds
                frozen.transform = webView.transform
                frozen.center = webView.center
                view.insertSubview(frozen, aboveSubview: webView)
            }
        }
        isHandedOff = true
        spinner.stopAnimating()
        webView.navigationDelegate = nil
        // Left where it is (under the frozen snapshot, if any) for its new home to move it straight
        // across: taking it out of the window in between would tell WebKit the page went hidden.
        layout.apply(to: webView)
        return LinkPreviewHandoff(
            webView: webView, contentController: contentController, appliedHost: appliedHost,
            appliedListsVersion: appliedListsVersion, requestedContentMode: settings.contentMode,
            effectiveContentMode: effectiveContentMode, requestedURL: url, card: card
        )
    }

    private var pageSize: CGSize {
        layout.size.width > 0 && layout.size.height > 0 ? layout.size : view.bounds.size
    }

    private var scale: CGFloat {
        pageSize.width > 0 ? view.bounds.width / pageSize.width : 1
    }

    /// The system's card clips the preview with rounded corners; the tab grows from the same shape.
    private var platterCornerRadius: CGFloat {
        var ancestor = view.superview
        while let current = ancestor {
            if current.layer.cornerRadius > 0 { return current.layer.cornerRadius }
            ancestor = current.superview
        }
        return 24
    }

    private func applyBlocking(host: String?) async {
        if let version = await blocking.apply(to: contentController, host: host) {
            appliedHost = host
            appliedListsVersion = version
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = settings.contentMode
        // Only what WebKit loads itself; never another app, and never our own scheme or files.
        guard !isStopped, let url = navigationAction.request.url,
              TabSession.webSchemes.contains(url.scheme?.lowercased() ?? "")
        else { return (.cancel, preferences) }
        if navigationAction.targetFrame?.isMainFrame == true {
            pendingMainFrameDecisions += 1
            defer { pendingMainFrameDecisions -= 1 }
            let host = url.host()?.lowercased()
            if host != appliedHost { await applyBlocking(host: host) }
        }
        return (isStopped || isHandedOff ? .cancel : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommitted = true
        if let navigation { effectiveContentMode = navigation.effectiveContentMode }
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        isBroken = true
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        isBroken = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isBroken = true
    }
}
