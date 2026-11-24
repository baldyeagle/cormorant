import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
@testable import Cormorant
@testable import CormorantBrowser

extension AppTests {
    /// The search panel's rows, as `SearchSheet` lists them (`shown(for:lookup:in:)`, with history
    /// looked up as the panel does) and as choosing one acts: a history row reopens a page no tab
    /// shows, an open tab is offered to switch to rather than load again, Search Tabs lists and
    /// filters open tabs, and composing a new tab, the tab it came from is the row to edit its address.
    /// Typing in the field (its inline completion, focus) is CormorantUITests' SearchSuggestionsTests.
    @Suite("Search panel")
    @MainActor
    struct SearchPanelTests {
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <script>
              document.getElementById('path').textContent = 'Path ' + location.pathname;
              document.title = 'Page ' + location.pathname.slice(1);
            </script>
            """

        @Test func historyRowReopensAPageNoTabShows() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            let alpha = server.url.appending(path: "alpha")
            try await browser.open(alpha)
            // The same tab moves on, so /alpha is only in history.
            browser.store.submit(server.url.appending(path: "beta").absoluteString)
            try await browser.waitForPage("/beta")
            #expect(browser.store.tabs.count == 1)

            // The bar's +, then "alpha".
            browser.store.newTab()
            let shown = await browser.panel(typing: "alpha")
            #expect(shown.openTabs.isEmpty, "a tab shows /alpha")
            let row = try #require(shown.pages.first { $0.url.path() == "/alpha" }, "no history row for /alpha")

            browser.store.open(historyPage: row.url)
            try await browser.waitForPage("/alpha")
            #expect(browser.store.tabs.count == 2, "composing, the row didn't open a new tab")
            #expect(Set(browser.store.tabs.compactMap { $0.url?.path() }) == ["/alpha", "/beta"])
            withExtendedLifetime(server) {}
        }

        @Test func openTabRowSwitchesInsteadOfLoadingAgain() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "alpha"))
            try await browser.open(server.url.appending(path: "beta"), inNewTab: true)
            #expect(browser.store.tabs.count == 2)

            browser.store.newTab()
            let shown = await browser.panel(typing: "alpha")
            let tab = try #require(shown.openTabs.first { $0.url?.path() == "/alpha" }, "no open-tab row for /alpha")
            // Listed once: the open tab hides its history entry.
            #expect(shown.rowPaths.filter { $0 == "/alpha" }.count == 1, "/alpha is listed \(shown.rowPaths)")

            // The row: switch, then the panel closes.
            browser.store.activate(tab.id)
            browser.store.cancelComposing()
            try await browser.waitForPage("/alpha")
            #expect(browser.store.tabs.count == 2, "switching opened another tab")
            #expect(server.requestCount(for: "/alpha") == 1, "switching loaded the page again")
            withExtendedLifetime(server) {}
        }

        /// Search Tabs (the switcher's, or the tab button's menu) lists every open tab, the current one
        /// too, filters them as you type, and Return switches to the match.
        @Test func searchTabsListsFiltersAndSwitches() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "alpha"))
            try await browser.open(server.url.appending(path: "beta"), inNewTab: true)

            browser.store.searchTabs()
            #expect(browser.store.isSearchingTabs)
            let all = SearchSheet.shown(for: nil, lookup: .init(), in: browser.store)
            #expect(all.tabsHeader == "2 Open Tabs", "the panel doesn't list both tabs")
            #expect(Set(all.openTabs.compactMap { $0.url?.path() }) == ["/alpha", "/beta"])

            let typed = "alph"
            let filtered = SearchSheet.shown(for: typed, lookup: .init(), in: browser.store)
            #expect(filtered.tabsHeader == "2 Open Tabs · 1 match", "the tabs weren't filtered")
            #expect(filtered.openTabs.map { $0.url?.path() } == ["/alpha"])

            // Return, then the panel closes.
            SearchSheet.submit(typed, shown: filtered, in: browser.store)
            browser.store.cancelComposing()
            try await browser.waitForPage("/alpha")
            #expect(browser.store.tabs.count == 2, "Return opened a tab")
            #expect(server.requestCount(for: "/alpha") == 1, "switching loaded the page again")
            withExtendedLifetime(server) {}
        }

        /// Composing a new tab, the tab it came from is listed first, to edit its address; choosing it
        /// stops composing, so what's submitted then loads in that tab rather than a new one. (That the
        /// field takes the address, selected, is NewTabTests' testEditRowSelectsTheTabsAddress.)
        @Test func editRowEditsTheCurrentTab() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let current = try #require(browser.store.state.activeTabID)

            browser.store.newTab()
            let shown = SearchSheet.shown(for: nil, lookup: .init(), in: browser.store)
            #expect(browser.store.isComposingNewTab)
            #expect(shown.openTabs.first?.id == current, "no row for the current tab")

            // The row (`editActiveTab`), then the new address and Return.
            browser.store.cancelComposing()
            let next = server.url.appending(path: "next").absoluteString
            SearchSheet.submit(next, shown: SearchSheet.shown(for: next, lookup: .init(), in: browser.store),
                               in: browser.store)
            try await browser.waitForPage("/next")
            #expect(browser.store.tabs.count == 1, "editing opened a new tab")
            #expect(browser.store.state.activeTabID == current)
            withExtendedLifetime(server) {}
        }
    }
}

fileprivate extension TestBrowser {
    /// What the panel lists once `text` is typed and history has answered: the visits of pages loaded
    /// so far are in (they're recorded as a page commits, queued before this lookup).
    func panel(typing text: String) async -> SearchSheet.Shown {
        _ = await store.afterBrowsingHistoryWrites { _ in }
        let lookup = await SearchSheet.historyLookup(for: text, in: store)
        return SearchSheet.shown(for: text, lookup: lookup, in: store)
    }
}

fileprivate extension SearchSheet.Shown {
    /// The paths of every page row: open tabs, history and closed tabs.
    var rowPaths: [String] {
        openTabs.compactMap { $0.url?.path() } + pages.map { $0.url.path() } + closed.map { $0.url.path() }
    }
}
