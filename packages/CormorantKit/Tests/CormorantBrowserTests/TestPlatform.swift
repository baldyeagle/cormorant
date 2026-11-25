import CormorantBrowser
import Foundation
import WebKit

/// A platform with no app around it: no window to stage tabs in, nothing announced.
final class TestPlatform: BrowserPlatform {
    private(set) var chromes: [TestChrome] = []

    func configure(_ configuration: WKWebViewConfiguration) {}

    func makeChrome(for session: TabSession, in store: BrowserStore) -> any TabChrome {
        let chrome = TestChrome()
        chromes.append(chrome)
        return chrome
    }

    func announce(_ message: String) {}
    var toastLifetime: Duration { .seconds(5) }
    var canAddPasses: Bool { false }
    func keepRunning(until task: Task<Void, Never>, named name: String) {}
    func prepareStage(from opener: WKWebView) {}
    var canStage: Bool { false }
    func stage(_ webView: WKWebView) {}
    func unstage(_ webView: WKWebView) {}
}

/// Answers every dialog with `answer`, and takes the Mac's file picker, as a Mac tab's chrome would.
final class TestChrome: NSObject, TabChrome, WKUIDelegate {
    enum Answer {
        case ok(String?)
        case cancel
    }

    var answer = Answer.ok(nil)
    /// What every link click asks for: a new tab, or (nil) to be followed here.
    var newTabForClicks: NewTabRequest?
    private(set) var dialogs: [String] = []

    func present(_ dialog: PageDialog) -> Bool {
        switch dialog {
        case .alert(_, let message, let done):
            dialogs.append("alert: \(message)")
            done()
        case .confirm(_, let message, let done):
            dialogs.append("confirm: \(message)")
            if case .ok = answer { done(true) } else { done(false) }
        case .prompt(_, let message, _, let done):
            dialogs.append("prompt: \(message)")
            if case .ok(let text) = answer { done(text) } else { done(nil) }
        case .openInOtherApp(let url, _):
            dialogs.append("open: \(url.absoluteString)")
        }
        return true
    }

    func pageBackground() -> PageBackground? { nil }
    func newTab(for click: WKNavigationAction) -> NewTabRequest? { newTabForClicks }
    func tabDidBecomeActive() {}
    func tabDidResignActive() {}
    func sessionDidDetach() {}

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        nil
    }

    /// A navigation delegate method, which the tab's own navigation delegate must not pass on.
    @objc func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {}
}
