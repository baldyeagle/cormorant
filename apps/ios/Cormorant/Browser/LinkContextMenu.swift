import UIKit
import WebKit

/// The long-press menu for links: open here, in a new tab or a background tab, copy, share, with a
/// live preview of http(s) pages. Tapping the preview opens the link here, like Safari.
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

    /// The preview was tapped: open the link in this tab.
    func commitLinkPreview(_ url: URL?, animator: any UIContextMenuInteractionCommitAnimating) {
        guard let url else { return }
        animator.preferredCommitStyle = .dismiss
        animator.addCompletion { [weak self] in self?.openLink(url) }
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
                self?.onOpenInNewTab?(url, false)
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

    /// The current page stays. The bar expands so the badge can be seen counting up, with a light tap
    /// and a VoiceOver announcement (queued, so the menu closing doesn't cut it off).
    private func openInBackgroundTab(_ url: URL) {
        onOpenInNewTab?(url, true)
        setBarCollapsed(false)
        UIImpactFeedbackGenerator(style: .light, view: webView).impactOccurred()
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
        let preview = LinkPreviewController(url: url, blocking: blocking, contentMode: requestedContentMode)
        // Small: about half the screen, full menu width.
        if let bounds = webView.window?.bounds {
            preview.preferredContentSize = CGSize(width: bounds.width, height: (bounds.height * 0.5).rounded())
        }
        linkPreview = preview
        return preview
    }
}

/// A throwaway web view showing a link's page under its long-press menu. Not a tab: it has its own
/// history, reports nothing to tab or saved state, opens no windows, other apps or dialogs (no UI
/// delegate), plays no media, and stops when the menu closes. Its rules match a tab's on the same host.
final class LinkPreviewController: UIViewController, WKNavigationDelegate {
    let url: URL
    private let blocking: BlockingService
    private let contentMode: WKWebpagePreferences.ContentMode
    private let contentController = WKUserContentController()
    private let webView: WKWebView
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Host the current rules were applied for.
    private var appliedHost: String?
    private var isStopped = false

    init(url: URL, blocking: BlockingService, contentMode: WKWebpagePreferences.ContentMode) {
        self.url = url
        self.blocking = blocking
        self.contentMode = contentMode
        let configuration = WKWebViewConfiguration()
        // Shared with tabs, so signed-in pages preview as they'll open.
        configuration.websiteDataStore = .default()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
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
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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

    /// Stops loading for good. The view itself goes when UIKit releases the preview.
    func stop() {
        isStopped = true
        webView.stopLoading()
    }

    private func applyBlocking(host: String?) async {
        if await blocking.apply(to: contentController, host: host) != nil { appliedHost = host }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = contentMode
        // Only what WebKit loads itself; never another app, and never our own scheme or files.
        guard !isStopped, let url = navigationAction.request.url,
              TabSession.webSchemes.contains(url.scheme?.lowercased() ?? "")
        else { return (.cancel, preferences) }
        if navigationAction.targetFrame?.isMainFrame == true {
            let host = url.host()?.lowercased()
            if host != appliedHost { await applyBlocking(host: host) }
        }
        return (isStopped ? .cancel : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        spinner.stopAnimating()
    }
}
