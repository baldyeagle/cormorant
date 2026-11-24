import AppKit
import CormorantBrowser
import WebKit

final class MacBrowserPlatform: BrowserPlatform {
    /// Writes the engine asked to see through, which quitting waits for.
    private var running: [UUID: Task<Void, Never>] = [:]

    func configure(_ configuration: WKWebViewConfiguration) {}

    func makeChrome(for session: TabSession, in store: BrowserStore) -> any TabChrome {
        MacTabChrome(session: session)
    }

    func announce(_ message: String) {
        guard let window = NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    var toastLifetime: Duration { .seconds(5) }
    var canAddPasses: Bool { false }

    func keepRunning(until task: Task<Void, Never>, named name: String) {
        let id = UUID()
        running[id] = task
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: name)
        Task {
            await task.value
            ProcessInfo.processInfo.endActivity(activity)
            running[id] = nil
        }
    }

    func finishRunning() async {
        while let (id, task) = running.first {
            await task.value
            running[id] = nil
        }
    }

    var canStage: Bool { false }
    func prepareStage(from opener: WKWebView) {}
    func stage(_ webView: WKWebView) {}
    func unstage(_ webView: WKWebView) {}
}
