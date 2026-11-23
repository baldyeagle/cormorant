import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
import UIKit
import WebKit
@testable import Cormorant

extension AppTests {
    /// Arc's back-to-close: going back from the first page of any tab closes it and returns to the tab
    /// viewed before it; before that, back is the tab's own history, kept across a relaunch. The swipe
    /// is carried through as the browser does once the page is off screen (`swipeBack()`); the gesture
    /// itself (short swipes springing back, landscape, the strip beside the page) and the caret sheet's
    /// Back button stay in CormorantUITests' BackSwipeCloseTests.
    @Suite("Back to close")
    @MainActor
    struct BackCloseTests {
        /// Every path serves this page; its heading names the path it was loaded at.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
            <h1 id="path">Path</h1>
            <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
            <a href="/next">Next page</a>
            <a href="/third">Third page</a>
            <a href="/popup" target="_blank">Blank target</a>
            """

        /// Open in New Tab, follow a link there, back, back: the swipe leaves the tab while it can go
        /// back (WebKit's own back swipe has the edge then), and the second back closes it.
        @Test func swipeBackClosesTabOpenedFromMenuOnlyOnItsFirstPage() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)

            // No preview up: the tab loads the link itself.
            try openInNewTab(server.url.appending(path: "next"), from: opener)
            #expect(browser.store.tabs.count == 2, "no new tab")
            try await browser.waitForPage("/next")
            try await browser.follow("Third page")
            try await browser.waitForPage("/third")

            #expect(try !browser.swipeBack(), "closed a tab that can go back")
            #expect(browser.store.tabs.count == 2)

            let session = try #require(browser.store.activeSession)
            #expect(session.canGoBack, "Back would close the tab instead of going back")
            session.goBack()
            try await browser.waitForPage("/next")
            #expect(browser.store.tabs.count == 2, "Back closed the tab instead of going back")

            #expect(try browser.swipeBack(), "the swipe didn't close the tab")
            #expect(browser.store.tabs.count == 1)
            #expect(browser.store.activeSession === opener, "didn't return to the previous tab")
            try await browser.waitForPage("/")
        }

        @Test func swipeBackClosesBlankTargetTab() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)

            try await browser.follow("Blank target")
            try await browser.until("a new tab") { browser.store.tabs.count == 2 }
            try await browser.waitForPage("/popup")

            #expect(try browser.swipeBack(), "the swipe didn't close the tab")
            #expect(browser.store.tabs.count == 1)
            #expect(browser.store.activeSession === opener, "didn't return to the previous tab")
            try await browser.waitForPage("/")
        }

        /// A tab's back history survives the app being killed and relaunched, as in Arc: back still goes
        /// to the new tab's first page, and only then closes it. Also covers the opener tab, which
        /// isn't shown after the relaunch until the close lands on it.
        @Test func historySurvivesRelaunch() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)

            try await browser.follow("Blank target")
            try await browser.until("a new tab") { browser.store.tabs.count == 2 }
            try await browser.waitForPage("/popup")
            try await browser.follow("Third page")
            try await browser.waitForPage("/third")

            try await relaunchAsIfKilled(browser, expecting: ["/popup", "/third"])
            try await browser.waitForPage("/third")
            #expect(browser.store.tabs.count == 2, "tab didn't come back")

            try await goBackFromCaret(browser)
            try await browser.waitForPage("/popup")
            #expect(browser.store.tabs.count == 2, "Back closed the tab instead of going back")

            #expect(try browser.swipeBack(), "the swipe didn't close the tab")
            #expect(browser.store.tabs.count == 1)
            try await browser.waitForPage("/")
        }

        /// A tab that adopted the link preview's page keeps its history like any tab: across a relaunch,
        /// back returns to that first page, and swiping back from there closes it.
        @Test func adoptedTabHistorySurvivesRelaunch() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let next = server.url.appending(path: "next")

            // The menu's preview, as UIKit asks the tab for it, with its page in.
            let preview = opener.makeLinkPreview(for: next)
            try await browser.until("the preview to load /next") {
                preview.webView.url?.path() == "/next" && !preview.webView.isLoading
            }
            try openInNewTab(next, from: opener)
            #expect(browser.store.tabs.count == 2, "no new tab")
            #expect(browser.store.activeSession?.webView === preview.webView, "the new tab didn't take the preview's page")
            try await browser.waitForPage("/next")
            #expect(server.requestCount(for: "/next") == 1, "the page was loaded again; \(server.requestLog)")
            try await browser.follow("Third page")
            try await browser.waitForPage("/third")

            try await relaunchAsIfKilled(browser, expecting: ["/next", "/third"])
            try await browser.waitForPage("/third")
            #expect(browser.store.tabs.count == 2, "tab didn't come back")

            try await goBackFromCaret(browser)
            try await browser.waitForPage("/next")
            #expect(browser.store.tabs.count == 2, "Back closed the tab instead of going back")

            #expect(try browser.swipeBack(), "the swipe didn't close the tab")
            #expect(browser.store.tabs.count == 1)
            try await browser.waitForPage("/")
        }

        // MARK: Helpers

        /// The long-press menu's Open in New Tab on `url`, chosen in `opener`; then the menu ends.
        private func openInNewTab(_ url: URL, from opener: TabSession,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
            let actions = opener.linkMenuActions(for: url, kind: TabSession.linkKind(for: url))
            let action = try #require(actions.open.first { $0.title == "Open in New Tab" }, sourceLocation: sourceLocation)
            action.perform()
            opener.linkMenuDidEnd(for: url)
        }

        /// The app killed while open, then opened again. That's the harder case: only the saves made
        /// while browsing have run, not the ones made as the app goes away, which `relaunch()` makes
        /// too. So once those saves have landed, the tab on screen's history file must already hold
        /// `paths`, before the relaunch.
        private func relaunchAsIfKilled(_ browser: TestBrowser, expecting paths: [String],
                                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let tabID = try #require(browser.store.activeTab?.id, sourceLocation: sourceLocation)
            try await browser.waitForSaves(sourceLocation: sourceLocation)
            let saved = try await browser.savedHistory(of: tabID, sourceLocation: sourceLocation)
            #expect(saved == paths, "the history saved while browsing isn't the tab's", sourceLocation: sourceLocation)
            try await browser.relaunch(sourceLocation: sourceLocation)
        }

        /// The caret sheet's Back on a tab that can go back (once its history is in after a relaunch):
        /// goes back rather than closing the tab.
        private func goBackFromCaret(_ browser: TestBrowser, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let session = try #require(browser.store.activeSession, sourceLocation: sourceLocation)
            try await browser.until("the tab's history to come back", sourceLocation: sourceLocation) {
                session.canGoBack && !session.isRestoringHistory
            }
            session.goBack()
        }
    }
}

fileprivate extension TestBrowser {
    /// A swipe in from the left edge, carried through: closes the tab on screen if the browser's
    /// swipe would (`BrowserView.backSwipeClose(for:in:)`, `WebViewContainer.swipeClosesTab`), as it
    /// does once the page is off screen. Returns whether it closed the tab.
    func swipeBack(sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool {
        let session = try #require(store.activeSession, sourceLocation: sourceLocation)
        guard let close = BrowserView.backSwipeClose(for: session, in: store),
              WebViewContainer.swipeClosesTab(close, webView: session.webView) else { return false }
        close.close()
        return true
    }

    /// The back/forward history in the tab's file on disk, as paths, oldest first: restored into a web
    /// view of its own, as a relaunch restores it.
    func savedHistory(of tabID: UUID, sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String] {
        let data = try Data(contentsOf: directory.appending(path: "History/\(tabID.uuidString).history"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { webView.stopLoading() }
        webView.interactionState = data
        try await until("the saved history to restore", sourceLocation: sourceLocation) {
            webView.backForwardList.currentItem != nil
        }
        let list = webView.backForwardList
        return (list.backList + [list.currentItem].compactMap { $0 } + list.forwardList).map { $0.url.path() }
    }
}
