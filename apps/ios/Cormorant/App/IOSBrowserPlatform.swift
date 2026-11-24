import PassKit
import UIKit
import WebKit

final class IOSBrowserPlatform: BrowserPlatform {
    private let backgroundStage = BackgroundPageStage()
    /// Where background tabs load, and at what size: the window and layout of the tab they were opened
    /// from, so they're ready to show as they are.
    private weak var stagingWindow: UIWindow?
    private var stagingLayout: PageLayout?

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.allowsInlineMediaPlayback = true
    }

    func makeChrome(for session: TabSession, in store: BrowserStore) -> any TabChrome {
        IOSTabChrome(session: session, platform: self, activeStripColor: { [weak store] in store?.stripUIColor(for: $0) })
    }

    var canAddPasses: Bool { PKAddPassesViewController.canAddPasses() }

    func announce(_ message: String) {
        let announcement = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    var toastLifetime: Duration { UIAccessibility.isVoiceOverRunning ? .seconds(15) : .seconds(5) }

    func keepRunning(until task: Task<Void, Never>, named name: String) {
        let application = UIApplication.shared
        let backgroundTask = application.beginBackgroundTask(withName: name, expirationHandler: nil)
        Task {
            await task.value
            application.endBackgroundTask(backgroundTask)
        }
    }

    func prepareStage(from opener: WKWebView) {
        guard let window = opener.window else { return }
        stagingWindow = window
        stagingLayout = PageLayout(of: opener)
    }

    var canStage: Bool { stagingWindow != nil && stagingLayout != nil }

    func stage(_ webView: WKWebView) {
        guard let window = stagingWindow, let layout = stagingLayout else { return }
        backgroundStage.add(webView, layout: layout, in: window)
    }

    func unstage(_ webView: WKWebView) {
        backgroundStage.remove(webView)
    }
}
