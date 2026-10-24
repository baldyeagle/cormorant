import UIKit
import WebKit

/// Navigation and UI delegate for one tab's web view. Forwards decisions to its `TabSession`.
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var session: TabSession?

    // MARK: Navigation

    /// Also where the tab's desktop/mobile choice is applied: WebKit picks the user agent and
    /// viewport for a navigation from the preferences returned here.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let session else { return (.allow, preferences) }
        preferences.preferredContentMode = session.requestedContentMode
        return (await session.policy(for: navigationAction), preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        session?.policy(for: navigationResponse) ?? .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session?.navigationDidStart()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let navigation { session?.navigationDidCommit(navigation) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session?.pageDidFinishLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        session?.navigationDidFail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        session?.navigationDidFail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session?.webContentProcessDidTerminate()
    }

    // MARK: Windows

    /// `target=_blank` links and `window.open` become new tabs. WebKit requires the returned view to be
    /// built from `configuration`; it then performs the navigation itself (or the opener scripts it).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        session?.createWebView(configuration: configuration, for: navigationAction)
    }

    func webViewDidClose(_ webView: WKWebView) {
        session?.pageDidRequestClose()
    }

    // MARK: Link menu
    // Implementing these keeps WebKit from falling back to the system's link menu, whose Open Link
    // and preview tap send the URL to the default browser instead of this tab.

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL else { return nil }
        return session?.linkMenuConfiguration(for: url)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating
    ) {
        session?.commitLinkPreview(elementInfo.linkURL, animator: animator)
    }

    func webView(_ webView: WKWebView, contextMenuDidEndForElement elementInfo: WKContextMenuElementInfo) {
        session?.linkMenuDidEnd(for: elementInfo.linkURL)
    }

    // MARK: JavaScript dialogs
    // Each handler must be called exactly once, so every path that can't show an alert calls it directly.

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = UIAlertController(title: Self.title(for: frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if !Self.present(alert, over: webView) { completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = UIAlertController(title: Self.title(for: frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if !Self.present(alert, over: webView) { completionHandler(false) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let alert = UIAlertController(title: Self.title(for: frame), message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        if !Self.present(alert, over: webView) { completionHandler(nil) }
    }

    /// Presents from the web view's window scene. Returns false if the web view isn't on screen.
    private static func present(_ alert: UIAlertController, over webView: WKWebView) -> Bool {
        guard let presenter = webView.alertPresenter else { return false }
        presenter.present(alert, animated: true)
        return true
    }

    private static func title(for frame: WKFrameInfo) -> String? {
        let host = frame.securityOrigin.host
        return host.isEmpty ? nil : host
    }
}
