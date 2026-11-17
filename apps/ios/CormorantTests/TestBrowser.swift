import CormorantCore
import Foundation
import Testing
import UIKit
import WebKit
@testable import Cormorant

/// The browser as the app builds it (`CormorantApp.makeStore` under `-uiTesting`), on files of its
/// own, launched, with the tab on screen shown in a window of its own so pages lay out, paint and
/// snapshot as they do in the app. `relaunch()` stands in for the app being killed and opened again:
/// everything goes to disk, the store is shut off as a killed process would be, and a new one loads
/// from the same files.
///
/// Waits poll in-process (`until`), every 20 ms: unlike a UI test's, a check here costs nothing and
/// slows nothing down. Each throws once its ceiling passes, so a test stops at what didn't happen.
@MainActor
final class TestBrowser {
    struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }

    /// Generous: only reached when a test is about to fail. A first page load on a loaded CI runner
    /// took up to 22 s through XCUITest; in-process it should be a fraction of that.
    static let ceiling: Duration = .seconds(60)

    let directory: URL
    /// The run's own inbox, where the share extension would put links (`share(_:toSpaceNamed:)`).
    let inbox: SharedInbox
    private(set) var store: BrowserStore
    private let defaultsSuite: String
    private let searchSuggestions: Bool
    private let stateFile: URL
    private let window: UIWindow
    private let host = PageHost()

    /// - Parameter state: what the browser finds saved at launch; none is a first launch.
    /// - Parameter searchEngine: a query template (`http://127.0.0.1:port/search?q=%s`) to use instead
    ///   of the default engine.
    init(state: BrowserState? = nil, searchEngine: String? = nil, searchSuggestions: Bool = false) async throws {
        directory = URL.temporaryDirectory.appending(path: "cormorant-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateFile = directory.appending(path: "state.json")
        inbox = SharedInbox(fileURL: directory.appending(path: "inbox.json"))
        defaultsSuite = "dev.baldyeagle.cormorant.tests.\(UUID().uuidString)"
        self.searchSuggestions = searchSuggestions
        if let state { try await JSONBrowserStateStore(fileURL: stateFile).save(state) }
        if let searchEngine {
            AppSettings(defaults: UserDefaults(suiteName: defaultsSuite)!).searchEngine =
                SearchEngine(id: AppSettings.customEngineID, name: "Fixture", queryTemplate: searchEngine)
        }
        window = try await Self.makeWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()
        store = Self.makeStore(directory: directory, stateFile: stateFile, inbox: inbox,
                               defaultsSuite: defaultsSuite, searchSuggestions: searchSuggestions)
        await store.launch()
        host.show(store.activeSession?.webView)
    }

    /// Shuts the browser off and throws away its files, settings and profiles' website data. Call it
    /// with `defer` right after making the browser.
    func close() {
        let profiles = store.state.profiles.map(\.id) + store.state.profilesToErase
        store.terminateForTesting()
        host.show(nil)
        window.isHidden = true
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: directory)
        // Only this test's profiles: their IDs are new, so no other test has a store by them.
        Task {
            for id in profiles where id != Profile.defaultID {
                try? await WKWebsiteDataStore.remove(forIdentifier: id)
            }
        }
    }

    // MARK: Waiting

    /// Returns once `condition` holds, checking at once and then every 20 ms (showing the tab on screen
    /// each time, as the browser screen would); records an issue and throws after `limit`.
    func until(_ what: @autoclosure () -> String, within limit: Duration = TestBrowser.ceiling,
               sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while true {
            host.show(store.activeSession?.webView)
            if condition() { return }
            guard ContinuousClock.now < deadline else {
                let failure = TimedOut(description: "\(limit) passed waiting for \(what())")
                Issue.record(failure, sourceLocation: sourceLocation)
                throw failure
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits until the tab on screen has finished loading `path` on the fixture server.
    func waitForPage(_ path: String, within limit: Duration = TestBrowser.ceiling,
                     sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until("the tab on screen to load \(path) (it's at \(store.activeSession?.webView.url?.absoluteString ?? "nothing"))",
                        within: limit, sourceLocation: sourceLocation) {
            guard let session = store.activeSession else { return false }
            return session.webView.url?.path() == path && !session.isLoading
        }
    }

    /// Waits until everything the browser writes while browsing is on disk.
    func waitForSaves(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until("the browser's saves to land", sourceLocation: sourceLocation) { !store.hasUnsavedWork }
    }

    // MARK: Acting

    /// Types `url` into the search panel and submits it, as a new tab when there is none, and waits for it.
    func open(_ url: URL, inNewTab: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        store.submit(url.absoluteString, inNewTab: inNewTab)
        try await waitForPage(url.path(), sourceLocation: sourceLocation)
    }

    /// What `script` (an expression) evaluates to in the tab on screen's page, as a string.
    func evaluate(_ script: String) async throws -> String? {
        guard let webView = store.activeSession?.webView else { return nil }
        return try await webView.evaluateJavaScript(script).map { "\($0)" }
    }

    /// As the share extension does with a Space picked (nil: none), then the app's `cormorant://open`.
    func share(_ url: URL, toSpaceNamed name: String? = nil) throws {
        let spaceID = name.flatMap { name in store.state.spaces.first { $0.name == name }?.id }
        try inbox.append(OpenRequest(url: url, spaceID: spaceID))
        store.handle(openURL: URL(string: "cormorant://open")!)
    }

    /// The app is killed once everything is on disk, and opened again, after `idleFor` (every tab last
    /// looked at that much earlier, as if the app had been away that long).
    func relaunch(idleFor idle: TimeInterval? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        store.didEnterBackground()
        try await waitForSaves(sourceLocation: sourceLocation)
        store.terminateForTesting()
        host.show(nil)
        if let idle {
            let file = JSONBrowserStateStore(fileURL: stateFile)
            var saved = try await file.load()
            for tab in saved.tabs { saved.markViewed(tabID: tab.id, now: tab.lastViewedAt - idle) }
            try await file.save(saved)
        }
        store = Self.makeStore(directory: directory, stateFile: stateFile, inbox: inbox,
                               defaultsSuite: defaultsSuite, searchSuggestions: searchSuggestions)
        await store.launch()
        host.show(store.activeSession?.webView)
    }

    // MARK: Building

    private static func makeStore(directory: URL, stateFile: URL, inbox: SharedInbox, defaultsSuite: String,
                                  searchSuggestions: Bool) -> BrowserStore {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        return BrowserStore(
            stateStore: JSONBrowserStateStore(fileURL: stateFile),
            historyStore: TabHistoryStore(directory: directory.appending(path: "History", directoryHint: .isDirectory)),
            blocking: BlockingService(usesFilterLists: false),
            settings: AppSettings(defaults: defaults),
            favicons: FaviconStore(directory: directory.appending(path: "Favicons", directoryHint: .isDirectory)),
            defaultBrowser: DefaultBrowserStatus(isLive: false),
            browsingHistory: BrowserStore.openBrowsingHistory(at: directory.appending(path: "browsing-history.sqlite")),
            searchSuggestions: searchSuggestions ? SearchSuggestionClient() : nil,
            focusFilter: FocusFilterSettings(defaults: defaults, followsSystem: false),
            inbox: inbox,
            spacesSummary: SpacesSummaryFile(fileURL: directory.appending(path: "spaces-summary.json"))
        )
    }

    /// A window on the host app's scene, once it's connected.
    private static func makeWindow() async throws -> UIWindow {
        let deadline = ContinuousClock.now + ceiling
        while true {
            if let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .normal + 1
                return window
            }
            guard ContinuousClock.now < deadline else { throw TimedOut(description: "the test host never connected a scene") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Holds the tab on screen's web view full-size, where the browser screen's container would.
private final class PageHost: UIViewController {
    private weak var shown: WKWebView?

    func show(_ webView: WKWebView?) {
        guard webView !== shown || webView?.superview !== view else { return }
        if let shown, shown.superview === view { shown.removeFromSuperview() }
        shown = webView
        guard let webView else { return }
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }
}
