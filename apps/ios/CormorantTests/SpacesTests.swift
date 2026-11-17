import CormorantCore
import Foundation
import Testing
@testable import Cormorant

extension AppTests {
    /// Switching Spaces lands on the tab last viewed in the Space, not its newest, or on nothing in an
    /// empty one (where the browser brings up the search panel). The strip, the menus and the panel
    /// itself stay in CormorantUITests' SpacesTests.
    @Suite("Spaces")
    @MainActor
    struct SpacesTests {
        /// Every path serves this page, which names its path.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <p>Spaces fixture.</p>
            <script>
              document.getElementById('path').textContent = 'Path ' + location.pathname;
              document.title = 'Tab ' + location.pathname;
            </script>
            """

        /// Back in a Space, its last viewed tab shows, not its newest; an empty Space on the way shows none.
        @Test func switchingBackReturnsToTheTabLeft() async throws {
            let server = try FixtureServer(html: Self.page)
            var state = BrowserState.empty
            let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo).id
            _ = state.openTab(url: server.url.appending(path: "work"), inSpace: work, activate: false)
            let trip = state.addSpace(name: "Trip", icon: .airplane, color: .green).id
            let browser = try await TestBrowser(state: state)
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            try await browser.open(server.url.appending(path: "b"), inNewTab: true)

            // Back to /a, the older tab, as its card does.
            let a = try #require(browser.store.tabs.first { $0.url?.path() == "/a" }?.id)
            browser.store.activate(a)
            try await browser.waitForPage("/a")

            // To Work, then to empty Trip: nothing on screen there.
            browser.store.switchToSpace(work)
            try await browser.waitForPage("/work")
            browser.store.switchToSpace(trip)
            #expect(browser.store.state.activeSpaceID == trip)
            #expect(browser.store.activeTab == nil, "empty Trip has an active tab")
            #expect(browser.store.activeSession == nil, "empty Trip shows a page")

            // And back to Home: /a, where it was left, and both its tabs.
            browser.store.switchToSpace(Space.defaultID)
            #expect(browser.store.state.activeTabID == a, "Home came back on another tab than /a")
            try await browser.waitForPage("/a")
            #expect(browser.store.tabs.compactMap { $0.url?.path() }.sorted() == ["/a", "/b"], "Home's tabs changed")
            withExtendedLifetime(server) {}
        }
    }
}
