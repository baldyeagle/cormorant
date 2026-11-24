import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
import WebKit
@testable import CormorantBrowser

/// The engine with no window, on a platform that only records what reaches it.
@Suite("Browser engine")
@MainActor
struct BrowserStoreTests {
    @Test func aTypedAddressOpensATabOnItsPage() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><p>Hello")
        let (store, platform, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        #expect(store.tabs.isEmpty)

        let session = try await Self.open(server.url.appending(path: "page"), in: store)
        #expect(store.tabs.count == 1)
        #expect(session.webView.url?.path() == "/page")
        #expect(platform.chromes.count == 1)
        withExtendedLifetime(server) {}
    }

    @Test func aPagesDialogsGoToTheTabsChromeAndItsAnswersBack() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><p>Hello")
        let (store, platform, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        let session = try await Self.open(server.url.appending(path: "page"), in: store)
        let chrome = try #require(platform.chromes.first)

        chrome.answer = .ok("typed")
        _ = try await session.webView.evaluateJavaScript("alert('one')")
        #expect(try await session.webView.evaluateJavaScript("confirm('two')") as? Bool == true)
        #expect(try await session.webView.evaluateJavaScript("prompt('three')") as? String == "typed")
        chrome.answer = .cancel
        #expect(try await session.webView.evaluateJavaScript("confirm('four')") as? Bool == false)
        #expect(try await session.webView.evaluateJavaScript("prompt('five') === null") as? Bool == true)
        #expect(chrome.dialogs == ["alert: one", "confirm: two", "prompt: three", "confirm: four", "prompt: five"])
        withExtendedLifetime(server) {}
    }

    @Test func theChromeGetsOnlyUIDelegateMethodsTheEngineDoesntImplement() async throws {
        let (store, platform, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><p>Hello")
        let session = try await Self.open(server.url.appending(path: "page"), in: store)
        let chrome = try #require(platform.chromes.first)
        let uiDelegate = try #require(session.webView.uiDelegate as? NSObject)
        let navigationDelegate = try #require(session.webView.navigationDelegate as? NSObject)

        let openPanel = #selector(WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:))
        #expect(uiDelegate.responds(to: openPanel))
        #expect(uiDelegate.forwardingTarget(for: openPanel) as? TestChrome === chrome)

        let alert = #selector(WKUIDelegate.webView(_:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:))
        #expect(uiDelegate.forwardingTarget(for: alert) == nil)

        let redirect = #selector(WKNavigationDelegate.webView(_:didReceiveServerRedirectForProvisionalNavigation:))
        #expect(chrome.responds(to: redirect))
        #expect(!navigationDelegate.responds(to: redirect))
        #expect(navigationDelegate.forwardingTarget(for: redirect) == nil)
        withExtendedLifetime(server) {}
    }

    /// The store's own files: a defaults suite and a temporary directory, removed by `end`.
    private struct Files {
        let suite: String
        let directory: URL
    }

    private static func makeStore() throws -> (BrowserStore, TestPlatform, Files) {
        let directory = URL.temporaryDirectory.appending(path: "cormorant-browser-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "dev.baldyeagle.cormorant.browser-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let platform = TestPlatform()
        let store = BrowserStore(
            stateStore: JSONBrowserStateStore(fileURL: directory.appending(path: "state.json")),
            historyStore: TabHistoryStore(directory: directory.appending(path: "History", directoryHint: .isDirectory)),
            blocking: BlockingService(usesFilterLists: false),
            settings: AppSettings(defaults: defaults),
            favicons: FaviconStore(directory: directory.appending(path: "Favicons", directoryHint: .isDirectory)),
            browsingHistory: nil,
            searchSuggestions: nil,
            focusFilter: FocusFilterSettings(defaults: defaults, systemFilterSpace: nil),
            inbox: nil,
            spacesSummary: nil,
            downloads: DownloadCenter(directory: directory.appending(path: "Downloads", directoryHint: .isDirectory)),
            platform: platform
        )
        return (store, platform, Files(suite: suite, directory: directory))
    }

    private static func end(_ store: BrowserStore, files: Files) {
        store.terminateForTesting()
        UserDefaults.standard.removePersistentDomain(forName: files.suite)
        try? FileManager.default.removeItem(at: files.directory)
    }

    /// Types `url` into a new tab and waits for its page to load.
    private static func open(_ url: URL, in store: BrowserStore) async throws -> TabSession {
        store.submit(url.absoluteString)
        let deadline = ContinuousClock.now + .seconds(60)
        while store.activeSession?.webView.url == nil || store.activeSession?.isLoading != false {
            guard ContinuousClock.now < deadline else {
                throw LoadTimeout(url: store.activeTab?.url)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(store.activeSession)
    }

    private struct LoadTimeout: Error {
        let url: URL?
    }
}
