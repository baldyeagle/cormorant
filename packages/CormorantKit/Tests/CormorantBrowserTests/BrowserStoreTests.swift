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

    @Test func reopenClosedTabBringsBackTheLastClosedFirst() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><p>Hello")
        let (store, _, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        for path in ["one", "two", "three"] {
            store.newTab()
            _ = try await Self.open(server.url.appending(path: path), in: store)
        }
        let byPath = Dictionary(uniqueKeysWithValues: store.tabs.compactMap { tab in tab.url.map { ($0.path(), tab.id) } })

        store.close(try #require(byPath["/two"]))
        store.close(try #require(byPath["/one"]))
        store.reopenClosedTab()
        #expect(store.activeTab?.url?.path() == "/one")
        store.reopenClosedTab()
        #expect(store.activeTab?.url?.path() == "/two")
        #expect(store.tabs.compactMap { $0.url?.path() }.sorted() == ["/one", "/three", "/two"])
        #expect(store.state.archived.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test func aNewSpaceTakesTheArchiveTimeItWasMadeWithAndIsShown() async throws {
        let (store, _, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()

        let reading = try #require(store.createSpace(name: " Reading ", icon: .book, color: .orange,
                                                     archivePolicy: .sevenDays))
        #expect(store.state.activeSpaceID == reading)
        #expect(store.state.space(reading)?.name == "Reading")
        #expect(store.state.space(reading)?.archivePolicy == .sevenDays)

        let work = try #require(store.createSpace(name: "Work", icon: .briefcase, color: .indigo))
        #expect(store.state.space(work)?.archivePolicy == .oneDay)
        #expect(store.createSpace(name: "  ", icon: .house, color: .teal) == nil)
        #expect(store.state.spaces.count == 3)
    }

    @Test func anAddressAnOpenTabIsOnOffersThatTab() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><p>Hello")
        let (store, _, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        for path in ["one", "two"] {
            store.newTab()
            _ = try await Self.open(server.url.appending(path: path), in: store)
        }
        let one = try #require(store.tabs.first { $0.url?.path() == "/one" })
        let two = try #require(store.activeTab)

        // Edited, the active tab isn't offered for its own page; another tab is, written as typed.
        #expect(AddressPanel.openTab(on: server.url.appending(path: "two"), in: store) == nil)
        let typed = try #require(URL(string: server.url.absoluteString.replacing("http://", with: "HTTP://") + "one/"))
        #expect(AddressPanel.openTab(on: typed, in: store)?.id == one.id)
        // Composing a new tab, the one it came from is offered too.
        store.newTab()
        #expect(AddressPanel.openTab(on: server.url.appending(path: "two"), in: store)?.id == two.id)
        #expect(AddressPanel.openTab(on: server.url.appending(path: "three"), in: store) == nil)
        withExtendedLifetime(server) {}
    }

    /// As a Mac's ⌘-click: the link opens in a background tab and this page stays where it is.
    @Test func aClickTheChromeTakesForANewTabOpensOneBehind() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><a href=\"/next\">Next</a>")
        let (store, platform, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        let session = try await Self.open(server.url.appending(path: "page"), in: store)
        try #require(platform.chromes.first).newTabForClicks = NewTabRequest(inBackground: true)

        _ = try await session.webView.evaluateJavaScript("document.links[0].click(), true")
        // Another tab: followed here instead, this tab would be the one on /next.
        try await Self.until("another tab on /next") {
            store.tabs.contains { $0.id != session.tabID && $0.url?.path() == "/next" }
        }
        #expect(store.activeSession === session)
        #expect(session.webView.url?.path() == "/page")
        withExtendedLifetime(server) {}
    }

    /// Pages opened from one are listed under it, in the order they were opened; a new tab goes first.
    @Test func tabsOpenedFromAPageAreListedUnderIt() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><a href=\"/a\">A</a><a href=\"/b\">B</a>")
        let (store, platform, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        _ = try await Self.open(server.url.appending(path: "first"), in: store)
        store.newTab()
        let session = try await Self.open(server.url.appending(path: "page"), in: store)
        try #require(platform.chromes.last).newTabForClicks = NewTabRequest(inBackground: true)

        for index in 0..<2 {
            _ = try await session.webView.evaluateJavaScript("document.links[\(index)].click(), true")
            try await Self.until("\(index + 1) tabs opened") { store.tabs.count == 3 + index }
        }
        #expect(store.listedTabs.map { $0.url?.path() } == ["/page", "/a", "/b", "/first"])
        // A `target=_blank` link, followed as is, goes under them too.
        platform.chromes.last?.newTabForClicks = nil
        _ = try await session.webView.evaluateJavaScript("""
            const link = Object.assign(document.createElement('a'), {href: '/c', target: '_blank'});
            document.body.append(link); link.click(); true
            """)
        try await Self.until("a tab on /c") { store.tabs.contains { $0.url?.path() == "/c" } }
        #expect(store.listedTabs.map { $0.url?.path() } == ["/page", "/a", "/b", "/c", "/first"])
        store.newTab()
        _ = try await Self.open(server.url.appending(path: "new"), in: store)
        #expect(store.listedTabs.first?.url?.path() == "/new")
        withExtendedLifetime(server) {}
    }

    /// The Mac's: a calendar file is a download like any other, for Finder to open.
    @Test func aCalendarFileIsADownloadWhenTheAppHandsNothingOff() async throws {
        let invite = Data("""
            BEGIN:VCALENDAR\r
            BEGIN:VEVENT\r
            SUMMARY:Launch\r
            DTSTART:20261201T180000Z\r
            END:VEVENT\r
            END:VCALENDAR\r

            """.utf8)
        let server = try FixtureServer(html: "<!doctype html><a href=\"/invite.ics\">Invite</a>",
                                       files: ["/invite.ics": .init(contentType: "text/calendar", body: invite)])
        let (store, _, files) = try Self.makeStore(handoffs: [])
        defer { Self.end(store, files: files) }
        await store.launch()
        let session = try await Self.open(server.url.appending(path: "page"), in: store)

        _ = try await session.webView.evaluateJavaScript("document.links[0].click(), true")
        try await Self.until("invite.ics to download") {
            store.downloads.listed.contains { $0.filename == "invite.ics" && $0.status == .finished }
        }
        #expect(store.calendarImport == nil)
        #expect(store.toast?.message == "Downloaded invite.ics")
        withExtendedLifetime(server) {}
    }

    /// A page that changes its own address while the app is in the background has its history written
    /// then: no debounced save is coming for it, as one does while the app is active.
    @Test func anAddressChangedInTheBackgroundLeavesNothingUnsaved() async throws {
        let server = try FixtureServer(html: "<!doctype html><title>Fixture page</title><p>Hello")
        let (store, _, files) = try Self.makeStore()
        defer { Self.end(store, files: files) }
        await store.launch()
        let session = try await Self.open(server.url.appending(path: "page"), in: store)
        store.didEnterBackground()
        try await Self.until("the page's saves to land") { !store.hasUnsavedWork }

        _ = try await session.webView.evaluateJavaScript("history.pushState({}, '', '/moved')")
        try await Self.until("the tab to take the new address") { store.activeTab?.url?.path() == "/moved" }

        try await Self.until("the moved page's history to be written") { !store.hasUnsavedWork }
        withExtendedLifetime(server) {}
    }

    /// The store's own files: a defaults suite and a temporary directory, removed by `end`.
    private struct Files {
        let suite: String
        let directory: URL
    }

    private static func makeStore(handoffs: Set<DownloadHandoff> = [.walletPass, .calendar, .arModel]) throws
        -> (BrowserStore, TestPlatform, Files) {
        let directory = URL.temporaryDirectory.appending(path: "cormorant-browser-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "dev.baldyeagle.cormorant.browser-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let platform = TestPlatform()
        let store = BrowserStore(
            stateStore: JSONBrowserStateStore(fileURL: directory.appending(path: "state.json")),
            historyStore: TabHistoryStore(directory: directory.appending(path: "History", directoryHint: .isDirectory)),
            blocking: BlockingService(usesFilterLists: false, cacheDirectory: directory.appending(path: "Blocking", directoryHint: .isDirectory),
                                      defaults: defaults),
            settings: AppSettings(defaults: defaults),
            favicons: FaviconStore(directory: directory.appending(path: "Favicons", directoryHint: .isDirectory)),
            browsingHistory: nil,
            searchSuggestions: nil,
            focusFilter: FocusFilterSettings(defaults: defaults, systemFilterSpace: nil),
            inbox: nil,
            spacesSummary: nil,
            downloads: DownloadCenter(directory: directory.appending(path: "Downloads", directoryHint: .isDirectory), handoffs: handoffs),
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

    private static func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct TimedOut: Error {
        let what: String
    }
}
