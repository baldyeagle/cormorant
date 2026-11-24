import Foundation
import WebKit

/// Navigation and UI delegate for one tab's web view. Forwards decisions to its `TabSession`, and UI
/// delegate methods it doesn't implement to the tab's chrome, if that's a UI delegate.
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak let session: TabSession?
    let chrome: any TabChrome
    private nonisolated(unsafe) let chromeDelegate: (any WKUIDelegate)?

    init(session: TabSession, chrome: any TabChrome) {
        self.session = session
        self.chrome = chrome
        chromeDelegate = chrome as? any WKUIDelegate
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardingTarget(for: selector) != nil
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        guard let chromeDelegate, chromeDelegate.responds(to: selector),
              protocol_getMethodDescription(WKUIDelegate.self, selector, false, true).name != nil
        else { return super.forwardingTarget(for: selector) }
        return chromeDelegate
    }

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

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        session?.navigationDidBecomeDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        session?.navigationDidBecomeDownload(download)
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
        session?.navigationDidFail(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        session?.navigationDidFail(navigation, error: error)
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

    // MARK: JavaScript dialogs
    // Each handler must be called exactly once, so every path that can't show an alert calls it directly.

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let dialog = PageDialog.alert(title: Self.title(for: frame), message: message, done: completionHandler)
        if session?.present(dialog) != true { completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let dialog = PageDialog.confirm(title: Self.title(for: frame), message: message, done: completionHandler)
        if session?.present(dialog) != true { completionHandler(false) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let dialog = PageDialog.prompt(title: Self.title(for: frame), message: prompt, defaultText: defaultText,
                                       done: completionHandler)
        if session?.present(dialog) != true { completionHandler(nil) }
    }

    private static func title(for frame: WKFrameInfo) -> String? {
        let host = frame.securityOrigin.host
        return host.isEmpty ? nil : host
    }
}
