import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
import WebKit
@testable import Cormorant

extension AppTests {
    /// Pinned tabs in the browser: pinning (a toast with Undo), closing one (it stays pinned, back on
    /// its page with nothing of where it went), Back to Pinned Page, a relaunch, and the tiles a new
    /// tab's panel shows. What a pin is (order, names, away from its page) is CormorantCore's PinTests;
    /// the switcher's row and the caret sheet's tile are CormorantUITests' PinnedTabsTests.
    @Suite("Pinned tabs")
    @MainActor
    struct PinsTests {
        /// Every path serves this page; its heading names the path, and it links to `/next`.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <a id="next" href="/next">Next</a>
            <script>document.title = 'Page ' + location.pathname</script>
            """

        @Test func pinningSaysSoAndUndoUnpins() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "mail"))
            let tab = try #require(browser.store.activeTab)

            #expect(browser.store.canPin(tab.id))
            browser.store.pin(tab.id)
            #expect(browser.store.state.tab(tab.id)?.isPinned == true)
            #expect(!browser.store.canPin(tab.id))
            #expect(browser.store.pinnedTabs.map(\.id) == [tab.id])
            #expect(browser.store.unpinnedTabs.isEmpty)
            let toast = try #require(browser.store.toast)
            #expect(toast.message == "Pinned")
            try #require(toast.actions.first { $0.title == "Undo" }).perform()
            #expect(browser.store.state.tab(tab.id)?.isPinned == false)
            #expect(browser.store.pinnedTabs.isEmpty)
            withExtendedLifetime(server) {}
        }

        /// Close, the back swipe from its first page included, leaves a pinned tab pinned and takes it
        /// back to its pinned page, as a fresh tab: its web view and back/forward list go, on disk too,
        /// and the tab viewed before it is shown.
        @Test func closingAPinnedTabResetsItAndKeepsThePin() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "home"))
            let home = try #require(browser.store.activeSession)
            try await browser.open(server.url.appending(path: "mail"), inNewTab: true)
            let pinned = try #require(browser.store.activeTab)
            browser.store.pin(pinned.id)
            _ = try await browser.evaluate("document.getElementById('next').click(), 1")
            try await browser.waitForPage("/next")
            try await browser.waitForSaves()
            #expect(browser.store.state.tab(pinned.id)?.isAwayFromPin == true)
            let historyFile = browser.directory.appending(path: "History/\(pinned.id.uuidString).history")
            #expect(FileManager.default.fileExists(atPath: historyFile.path(percentEncoded: false)))

            browser.store.close(pinned.id)
            #expect(browser.store.activeSession === home, "didn't go back to the tab before")
            let reset = try #require(browser.store.pinnedTabs.first)
            #expect(browser.store.pinnedTabs.count == 1)
            #expect(reset.id != pinned.id && reset.url == server.url.appending(path: "mail") && !reset.isAwayFromPin)
            #expect(browser.store.state.archived.isEmpty, "the pinned tab was archived")
            #expect(browser.store.existingSession(for: pinned.id) == nil, "its web view stayed")
            try await browser.waitForSaves()
            #expect(!FileManager.default.fileExists(atPath: historyFile.path(percentEncoded: false)),
                    "its back/forward list stayed on disk")

            // Shown again, it loads its pinned page, with nothing to go back to: a back swipe closes it
            // again, still pinned.
            browser.store.activate(reset.id)
            try await browser.waitForPage("/mail")
            let session = try #require(browser.store.activeSession)
            #expect(!session.canGoBack)
            let close = try #require(BrowserView.backSwipeClose(for: session, in: browser.store))
            #expect(WebViewContainer.swipeClosesTab(close, webView: session.webView))
            close.close()
            #expect(browser.store.activeSession === home)
            #expect(browser.store.pinnedTabs.count == 1)
            withExtendedLifetime(server) {}
        }

        /// Back to Pinned Page on the tab on screen loads its page as a link would: Back returns.
        @Test func backToPinnedPageLoadsItInPlace() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "mail"))
            let tab = try #require(browser.store.activeTab)
            browser.store.pin(tab.id)
            _ = try await browser.evaluate("document.getElementById('next').click(), 1")
            try await browser.waitForPage("/next")

            browser.store.backToPinnedPage(tab.id)
            try await browser.waitForPage("/mail")
            #expect(browser.store.activeTab?.id == tab.id)
            #expect(browser.store.activeTab?.isAwayFromPin == false)
            #expect(browser.store.activeSession?.canGoBack == true)
            withExtendedLifetime(server) {}
        }

        /// Pins come back after a relaunch, with their page and name, and a month away archives the other
        /// tabs but never them.
        @Test func pinsSurviveARelaunchAndNeverArchive() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "mail"))
            let pinned = try #require(browser.store.activeTab)
            browser.store.pin(pinned.id)
            browser.store.renamePin(pinned.id, to: "Mail")
            try await browser.open(server.url.appending(path: "other"), inNewTab: true)
            let other = try #require(browser.store.activeTab)
            // On screen, a tab never archives: a third one is.
            try await browser.open(server.url.appending(path: "third"), inNewTab: true)

            try await browser.relaunch(idleFor: 31 * 24 * 60 * 60)
            let tab = try #require(browser.store.state.tab(pinned.id))
            #expect(tab.isPinned && tab.pinName == "Mail" && tab.pinnedURL == server.url.appending(path: "mail"))
            #expect(browser.store.state.tab(other.id) == nil, "the other tab didn't archive")
            #expect(browser.store.state.archived.map(\.id) == [other.id])
            withExtendedLifetime(server) {}
        }

        /// A new tab's panel starts with the Space's pins as tiles, which its open tabs then leave out;
        /// not while editing this tab's address, in Search Tabs, or once something's typed.
        @Test func aNewTabsPanelShowsThePins() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "mail"))
            let pinned = try #require(browser.store.activeTab)
            browser.store.pin(pinned.id)
            try await browser.open(server.url.appending(path: "other"), inNewTab: true)
            let other = try #require(browser.store.activeTab)

            browser.store.newTab()
            var shown = SearchSheet.shown(for: nil, lookup: .init(), in: browser.store)
            #expect(shown.pins.map(\.id) == [pinned.id])
            #expect(!shown.openTabs.contains { $0.id == pinned.id })
            #expect(shown.openTabs.contains { $0.id == other.id })
            shown = SearchSheet.shown(for: "mail", lookup: .init(), in: browser.store)
            #expect(shown.pins.isEmpty)

            browser.store.cancelComposing()
            shown = SearchSheet.shown(for: nil, lookup: .init(), in: browser.store)
            #expect(shown.pins.isEmpty, "editing this tab's address showed the pins")
            browser.store.searchTabs()
            shown = SearchSheet.shown(for: nil, lookup: .init(), in: browser.store)
            #expect(shown.pins.isEmpty, "Search Tabs showed the pins")
            browser.store.cancelComposing()

            // Not in Incognito, which has none and lists only what's typed.
            browser.store.newTab()
            browser.store.setComposesIncognito(true)
            shown = SearchSheet.shown(for: nil, lookup: .init(), in: browser.store)
            #expect(shown.pins.isEmpty)
            withExtendedLifetime(server) {}
        }
    }
}
