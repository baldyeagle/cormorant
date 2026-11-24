import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
import WebKit
@testable import Cormorant
@testable import CormorantBrowser

extension AppTests {
    /// Incognito keeps nothing: its tabs, their back/forward lists, visits and icons never reach disk,
    /// so a relaunch finds none of them. Its tabs share one in-memory website data store, apart from
    /// every profile's, which goes when the last of them closes. Links from other apps never open there.
    /// The panel's Incognito button and the screens stay in CormorantUITests' IncognitoTests.
    @Suite("Incognito")
    @MainActor
    struct IncognitoTests {
        /// Every path serves this page. It sets the cookie `probe` to whatever follows `/set/`, shows the
        /// `probe` its website data has, and links to `/next`.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <link rel="icon" href="/icon.png">
            <title>Fixture</title>
            <p id="cookie">Cookie</p>
            <a id="next" href="/next">Next</a>
            <script>
              const set = location.pathname.match(/^\\/set\\/(\\w+)$/)
              if (set) document.cookie = 'probe=' + set[1] + '; path=/; max-age=86400'
              const probe = document.cookie.split('; ').find(c => c.startsWith('probe='))
              document.getElementById('cookie').textContent = 'Cookie ' + (probe || 'none')
              document.title = 'Page ' + location.pathname.slice(1)
            </script>
            """

        @Test func nothingOfIncognitoSurvivesARelaunch() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "home"))
            let homeTab = try #require(browser.store.activeTab)

            let token = Self.token()
            try await browser.openIncognito(server.url.appending(path: "secret-\(token)"))
            let incognitoTab = try #require(browser.store.activeTab)
            #expect(incognitoTab.isIncognito)
            #expect(browser.store.state.activeSpaceID == Space.incognitoID)
            #expect(browser.store.activeSession?.webView.configuration.websiteDataStore.isPersistent == false)
            // A second page, so it has a back/forward list to save.
            _ = try await browser.evaluate("document.getElementById('next').click(), 1")
            try await browser.waitForPage("/next")
            try await browser.waitForSaves()

            // Nothing written: tabs, its back/forward list, its visits.
            let saved = try await JSONBrowserStateStore(fileURL: browser.directory.appending(path: "state.json")).load()
            #expect(saved.tabs.map(\.id) == [homeTab.id])
            #expect(saved.activeSpaceID == Space.defaultID && saved.activeTabID == homeTab.id)
            let histories = (try? FileManager.default.contentsOfDirectory(atPath: browser.directory.appending(path: "History").path())) ?? []
            #expect(!histories.contains { $0.contains(incognitoTab.id.uuidString) }, "its back/forward list was saved")
            let visited = await browser.store.afterBrowsingHistoryWrites { history in
                var found = 0
                for profile in await history.profiles().union([Profile.defaultID, Profile.incognitoID]) {
                    found += await history.pages(matching: token, profile: profile).count
                }
                return found
            }
            #expect(visited == 0, "an Incognito page is in the history")
            let summary = SpacesSummaryFile(fileURL: browser.directory.appending(path: "spaces-summary.json")).read()
            #expect(summary?.activeSpaceID == Space.defaultID)
            #expect(summary?.spaces.contains { $0.id == Space.incognitoID } == false)

            try await browser.relaunch()
            #expect(!browser.store.state.isIncognitoOpen)
            #expect(browser.store.state.activeSpaceID == Space.defaultID)
            #expect(browser.store.activeTab?.id == homeTab.id)
            withExtendedLifetime(server) {}
        }

        /// Incognito's tabs share their sign-ins with each other and nobody else, and lose them once the
        /// last one closes, which goes back to the tab before.
        @Test func incognitoHasWebsiteDataOfItsOwnUntilItsLastTabCloses() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            let home = Self.token(), first = Self.token()
            try await browser.open(server.url.appending(path: "set/\(home)"))
            let homeTab = try #require(browser.store.activeTab)

            try await browser.openIncognito(server.url.appending(path: "check"))
            #expect(try await browser.cookieShown() == "Cookie none", "Incognito sees Home's cookie")
            try await browser.open(server.url.appending(path: "set/\(first)"))

            // New Tab in Incognito composes another Incognito tab, which has the first one's cookie.
            browser.store.newTab()
            #expect(browser.store.composesIncognito)
            try await browser.open(server.url.appending(path: "again"))
            #expect(browser.store.activeTab?.isIncognito == true)
            #expect(try await browser.cookieShown() == "Cookie probe=\(first)", "Incognito tabs don't share a cookie")
            #expect(browser.store.state.tabs(inSpace: Space.incognitoID).count == 2)

            for tab in browser.store.state.tabs(inSpace: Space.incognitoID) { browser.store.close(tab.id) }
            #expect(!browser.store.state.isIncognitoOpen)
            #expect(browser.store.activeTab?.id == homeTab.id)
            #expect(browser.store.state.archived.isEmpty, "a closed Incognito tab was archived")
            #expect(!IncognitoData.isActive)
            #expect(browser.store.toast?.message == "Incognito closed")
            try await browser.waitForPage("/set/\(home)")

            // A new Incognito starts with nothing.
            try await browser.openIncognito(server.url.appending(path: "fresh"))
            #expect(try await browser.cookieShown() == "Cookie none", "Incognito kept its cookie after it closed")
            withExtendedLifetime(server) {}
        }

        /// A link from an Incognito tab's menu stays in Incognito; Open in Incognito takes one there from
        /// any tab; New Tab with the panel's button off leaves Incognito.
        @Test func linksOpenInIncognitoAndOut() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "home"))
            let home = try #require(browser.store.activeSession)

            #expect(browser.store.openLinkInIncognito(server.url.appending(path: "a"), from: home))
            try await browser.waitForPage("/a")
            #expect(browser.store.activeTab?.isIncognito == true)
            let incognito = try #require(browser.store.activeSession)
            #expect(incognito.spacesToOpenLinksIn?().isEmpty == true)

            #expect(browser.store.openLinkInNewTab(server.url.appending(path: "b"), inBackground: false,
                                                   from: incognito, handoff: nil))
            try await browser.waitForPage("/b")
            #expect(browser.store.activeTab?.isIncognito == true)

            browser.store.newTab()
            browser.store.setComposesIncognito(false)
            try await browser.open(server.url.appending(path: "c"))
            #expect(browser.store.activeTab?.isIncognito == false)
            #expect(browser.store.state.activeSpaceID == Space.defaultID)
            #expect(browser.store.state.tabs(inSpace: Space.incognitoID).count == 2)
            withExtendedLifetime(server) {}
        }

        /// Search Tabs' Go in Incognito opens an Incognito tab, as New Tab there does, and the panel keeps
        /// to what's typed meanwhile. A link opened in a background tab from an Incognito tab is Incognito.
        @Test func searchTabsAndBackgroundTabsStayInIncognito() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "home"))
            try await browser.openIncognito(server.url.appending(path: "a"))
            let incognito = try #require(browser.store.activeSession)

            #expect(browser.store.openLinkInNewTab(server.url.appending(path: "background"), inBackground: true,
                                                   from: incognito, handoff: nil))
            let background = try #require(browser.store.state.tabs.first { $0.url?.path() == "/background" })
            #expect(background.isIncognito)
            #expect(browser.store.activeSession === incognito)

            browser.store.searchTabs()
            #expect(browser.store.searchesPrivately)
            browser.store.submit(server.url.appending(path: "found").absoluteString, inNewTab: true)
            try await browser.waitForPage("/found")
            #expect(browser.store.activeTab?.isIncognito == true)
            #expect(browser.store.state.activeSpaceID == Space.incognitoID)
            #expect(browser.store.activeSession?.webView.configuration.websiteDataStore.isPersistent == false)
            withExtendedLifetime(server) {}
        }

        /// A link from another app opens outside Incognito, in the Space it went back to.
        @Test func linksFromOtherAppsOpenOutsideIncognito() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "home"))
            try await browser.openIncognito(server.url.appending(path: "private"))

            try browser.share(server.url.appending(path: "shared"))
            try await browser.waitForPage("/shared")
            #expect(browser.store.activeTab?.isIncognito == false)
            #expect(browser.store.state.activeSpaceID == Space.defaultID)
            #expect(browser.store.state.isIncognitoOpen)
            withExtendedLifetime(server) {}
        }

        private static func token() -> String { "t" + UUID().uuidString.prefix(8).lowercased() }
    }
}

fileprivate extension TestBrowser {
    /// New Tab with the search panel's Incognito button on, then `url` submitted.
    func openIncognito(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        store.newTab()
        store.setComposesIncognito(true)
        try await open(url, sourceLocation: sourceLocation)
    }

    func cookieShown() async throws -> String? {
        try await evaluate("document.getElementById('cookie').textContent")
    }
}
