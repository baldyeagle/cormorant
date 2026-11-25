import AppKit
import CormorantBrowser
import WebKit

/// Somewhere in the window, out of sight, for background tabs to load at the size they'll be shown.
protocol BackgroundTabStage: AnyObject {
    /// In a window: WebKit only loads a page in a web view that is.
    var holdsTabs: Bool { get }
    func add(_ webView: WKWebView)
    func remove(_ webView: WKWebView)
}

final class MacBrowserPlatform: BrowserPlatform {
    /// The page area, once the window has one.
    weak var backgroundStage: BackgroundTabStage?

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

    var canStage: Bool { backgroundStage?.holdsTabs == true }
    /// Every tab is shown at the page area's size, whichever tab opened it.
    func prepareStage(from opener: WKWebView) {}
    func stage(_ webView: WKWebView) { backgroundStage?.add(webView) }
    func unstage(_ webView: WKWebView) { backgroundStage?.remove(webView) }
}
