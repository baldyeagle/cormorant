import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
@testable import Cormorant

extension AppTests {
    /// Moving a tab to another Space (what the caret sheet's Move to Space sheet calls), opening a link in
    /// another Space (the link menu's Open in Space), and the toasts that say where the tab went: Undo and
    /// Back to the Space left after a move (which takes you with the tab), Show after Open in Space, and
    /// Move… for a link from another app. Seeded as `-uiTestingSpaces` does: Work (on the Vialumi
    /// profile, so moving there reloads) and Projects with one tab each, and an empty Trip, beside Home.
    /// With only Home none of it shows.
    ///
    /// A toast's button is `tapToast`, which does what the button does. Toasts are acted on as soon as
    /// they're up, before their five seconds can run out, or held up (`holdToast`) while a page loads.
    @Suite("Move to Space")
    @MainActor
    struct MoveToSpaceTests {
        /// Every path serves this page, which names its path.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <script>
              document.getElementById('path').textContent = 'Path ' + location.pathname;
              document.title = 'Tab ' + location.pathname;
            </script>
            """

        /// From the Move sheet: the page on screen goes to Projects and stays on screen, the toast's Undo
        /// takes it back to Home, and its Back to Home shows Home's other tab, leaving it in Projects.
        @Test func moveFromTheSheetThenUndoAndBack() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            try await browser.open(server.url.appending(path: "b"), inNewTab: true)
            let b = try #require(browser.store.activeTab?.id)
            let projects = try browser.spaceID(named: "Projects")

            // The sheet lists every Space, the tab's own not choosable; Work's profile isn't Home's.
            let destinations = browser.store.moveDestinations(for: b)
            #expect(destinations.map(\.space.name) == ["Home", "Work", "Projects", "Trip"])
            #expect(destinations.map(\.isCurrent) == [true, false, false, false], "the tab's own Space can be chosen")
            #expect(destinations.map(\.subtitle) == ["Here now", "1 tab · Vialumi profile · Reloads", "1 tab", "0 tabs"])

            browser.store.moveTab(b, toSpace: projects)
            var toast = try #require(browser.store.toast, "no toast after the move")
            #expect(toast.spokenText == "Moved to Projects")
            #expect(toast.allActions.map(\.title) == ["Back to Home", "Undo"])
            #expect(browser.store.state.activeSpace.name == "Projects", "the move didn't go to Projects")
            #expect(browser.store.activeTab?.id == b, "the moved page left the screen")
            #expect(browser.store.activeSession?.tabID == b)
            #expect(browser.store.tabs.count == 2, "Projects doesn't have the moved tab")

            try browser.tapToast("Undo")
            #expect(browser.store.toast == nil, "the toast stayed after Undo")
            #expect(browser.store.state.activeSpace.name == "Home", "Undo didn't go back to Home")
            #expect(browser.store.activeTab?.id == b, "Undo didn't keep the page on screen")
            #expect(browser.store.tabs.count == 2, "Home's tabs didn't come back")
            try await browser.waitForPage("/b")

            browser.store.moveTab(b, toSpace: projects)
            toast = try #require(browser.store.toast, "no toast after the second move")
            #expect(toast.spokenText == "Moved to Projects")
            try browser.tapToast("Back to Home")
            #expect(browser.store.state.activeSpace.name == "Home", "Back didn't go to Home")
            #expect(browser.store.activeTab?.url?.path() == "/a", "Back didn't show Home's other tab")
            #expect(browser.store.tabs.count == 1, "the moved tab came back with Back")
            #expect(browser.store.state.tab(b)?.spaceID == projects, "the moved tab left Projects")
            try await browser.waitForPage("/a")
            withExtendedLifetime(server) {}
        }

        /// Moving a Space's last tab goes with it; Back to the Space left, empty now, leaves no tab on
        /// screen there, which brings up the search panel (the browser's `searchIfBlank`).
        @Test func backToASpaceLeftEmptyLeavesNoTab() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            let a = try #require(browser.store.activeTab?.id)

            let work = try browser.spaceID(named: "Work")
            browser.store.moveTab(a, toSpace: work)
            #expect(browser.store.toast != nil, "no toast after the move")
            // Kept up while the page reloads on Work's profile, as VoiceOver on it would.
            browser.store.holdToast(true)
            #expect(browser.store.state.activeSpace.name == "Work")
            #expect(browser.store.activeTab?.id == a, "the moved page isn't on screen in Work")
            try await browser.waitForPage("/a")
            #expect(browser.store.activeTab?.id == a, "the moved page left the screen in Work")
            #expect(browser.store.state.tabs(inSpace: Space.defaultID).isEmpty, "Home kept a tab")

            try browser.tapToast("Back to Home")
            #expect(browser.store.state.activeSpace.name == "Home", "Back didn't go to Home")
            #expect(browser.store.activeTab == nil, "the empty Space has a tab on screen")
            #expect(browser.store.activeSession == nil, "the empty Space has a page on screen")
            #expect(browser.store.state.tab(a)?.spaceID == work, "the moved tab came back with Back")
            withExtendedLifetime(server) {}
        }

        /// The link menu's Open in Space opens the link in a background tab there: no switch, a toast with
        /// Show, which goes to it.
        @Test func openInSpaceFromTheLinkMenuDoesNotSwitch() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            let session = try #require(browser.store.activeSession)

            // Only the other Spaces, each with its profile where it isn't the default.
            let spacesToOpenLinksIn = try #require(session.spacesToOpenLinksIn, "no Open in Space")
            let options = spacesToOpenLinksIn()
            #expect(options.map(\.space.name) == ["Work", "Projects", "Trip"], "the current Space is under Open in Space")
            #expect(options.map(\.profileName) == ["Vialumi", nil, nil])
            // The preview's page goes along only to a Space on this tab's profile, whose website data it
            // was loaded with.
            #expect(options.map(\.adoptsPreview) == [false, true, true])
            let projects = try #require(options.first { $0.space.name == "Projects" })

            // As the menu item does: no preview was made, so the tab loads the link itself, and the bar
            // comes back so the new tab's count can be seen.
            session.setBarCollapsed(true)
            session.openInSpace(server.url.appending(path: "next"), option: projects)
            #expect(!session.isBarCollapsed, "the bar stayed collapsed")
            let toast = try #require(browser.store.toast, "no toast after Open in Space")
            #expect(toast.message == "Opened in Projects")
            #expect(toast.allActions.map(\.title) == ["Show"])
            #expect(browser.store.state.activeSpace.name == "Home", "Open in Space switched Spaces")
            #expect(browser.store.activeSession === session, "Open in Space left the page")
            #expect(browser.store.tabs.count == 1, "the tab opened in Home")

            try browser.tapToast("Show")
            #expect(browser.store.state.activeSpace.name == "Projects", "Show didn't switch to Projects")
            #expect(browser.store.activeTab?.url?.path() == "/next", "Show didn't show the new tab")
            #expect(browser.store.tabs.count == 2, "Projects doesn't have the new tab")
            try await browser.waitForPage("/next")
            withExtendedLifetime(server) {}
        }

        /// A link from another app opens in the Space you're in, straight to the page; the toast says
        /// which and its Move… asks for the Move sheet, which moves it on, the page with you.
        @Test func linkFromAnotherAppShowsWhereItOpened() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))

            browser.openFromAnotherApp(server.url.appending(path: "shared"))
            #expect(browser.store.activeTab?.url?.path() == "/shared", "the link didn't open")
            let shared = try #require(browser.store.activeTab?.id)
            let toast = try #require(browser.store.toast, "no toast for a link from another app")
            #expect(toast.message == "Opened in Home", "the toast doesn't name the Space")

            try browser.tapToast("Move…")
            #expect(browser.store.moveRequest?.tabID == shared, "Move… didn't ask for the Move sheet")
            // The sheet's Work row, then its `onMoved`.
            let work = try browser.spaceID(named: "Work")
            browser.store.moveTab(shared, toSpace: work)
            browser.store.moveRequest = nil
            #expect(browser.store.toast?.spokenText == "Moved to Work", "no toast after Move…")
            #expect(browser.store.state.activeSpace.name == "Work", "Move… didn't go to Work")
            #expect(browser.store.activeTab?.id == shared, "the moved page left the screen")
            try await browser.waitForPage("/shared")
            withExtendedLifetime(server) {}
        }

        /// Left alone, a toast goes by itself (five seconds; fifteen with VoiceOver).
        @Test func toastGoesAwayOnItsOwn() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            #expect(browser.store.toastsShown == 0)
            #expect(browser.store.toast == nil)

            browser.openFromAnotherApp(server.url.appending(path: "shared"))
            #expect(browser.store.toastsShown == 1)
            #expect(browser.store.toast != nil, "no toast for the link")
            let shared = try #require(browser.store.activeTab?.id)
            try await browser.until("the toast to go on its own") { browser.store.toast == nil }
            #expect(browser.store.toastsShown == 1)
            // Not taken down for its tab or its Space.
            #expect(browser.store.state.tab(shared) != nil)
            #expect(browser.store.hasSpacesToSwitch)
            try await browser.waitForPage("/shared")
            withExtendedLifetime(server) {}
        }

        /// With only Home: no Move to Space row (`shownSpace`), no card menu (`hasSpacesToSwitch`), no
        /// moves, no Open in Space, and no toast for a link from another app.
        @Test func oneSpaceShowsNoMovesOrToasts() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            let a = try #require(browser.store.activeTab?.id)
            let session = try #require(browser.store.activeSession)

            #expect(browser.store.shownSpace == nil, "Move to Space shows with only Home")
            #expect(!browser.store.hasSpacesToSwitch, "a card has a Move menu with only Home")
            #expect(browser.store.moveDestinations(for: a).isEmpty, "a card has a Move menu with only Home")
            #expect(session.spacesToOpenLinksIn?().isEmpty == true, "Open in Space shows with only Home")
            browser.store.requestMove(of: a)
            #expect(browser.store.moveRequest == nil, "a Move sheet with only Home")

            browser.openFromAnotherApp(server.url.appending(path: "shared"))
            #expect(browser.store.activeTab?.url?.path() == "/shared", "the link didn't open")
            try await browser.waitForPage("/shared")
            #expect(browser.store.toast == nil, "a toast with only Home")
            #expect(browser.store.toastsShown == 0, "a toast came and went with only Home")
            withExtendedLifetime(server) {}
        }

        // MARK: Helpers

        /// What `-uiTestingSpaces` seeds (`BrowserStore.seedUITestingSpaces`): beside Home, Work on a
        /// profile of its own ("Vialumi") and Projects, with a tab each, then Trip with none. Home is active.
        private func seededSpaces(_ base: URL) -> BrowserState {
            var state = BrowserState.empty
            let vialumi = state.addProfile(name: "Vialumi", color: .indigo)
            let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo, profileID: vialumi.id)
            let projects = state.addSpace(name: "Projects", icon: .hammer, color: .orange)
            _ = state.openTab(url: base.appending(path: "work"), inSpace: work.id, activate: false)
            _ = state.openTab(url: base.appending(path: "projects"), inSpace: projects.id, activate: false)
            state.addSpace(name: "Trip", icon: .airplane, color: .green)
            return state
        }
    }
}

fileprivate extension TestBrowser {
    /// As the system hands the app a link another app opened, with Cormorant the default browser.
    func openFromAnotherApp(_ url: URL) {
        var components = URLComponents(string: "cormorant://open")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        store.handle(openURL: components.url!)
    }

    func spaceID(named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> UUID {
        try #require(store.state.spaces.first { $0.name == name }?.id, "no Space named \(name)",
                     sourceLocation: sourceLocation)
    }

    /// What the toast's button titled `title` does (`ToastView`): the toast goes, then its action runs.
    func tapToast(_ title: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let toast = try #require(store.toast, "no toast to tap \(title) on", sourceLocation: sourceLocation)
        let action = try #require(toast.allActions.first { $0.title == title },
                                  "no \(title) on the toast (\(toast.allActions.map(\.title)))",
                                  sourceLocation: sourceLocation)
        store.dismissToast(toast.id)
        action.perform()
    }
}
