import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
@testable import Cormorant
@testable import CormorantBrowser

extension AppTests {
    /// Where links from other apps open: in the Space the share extension picked, else the Space a Focus
    /// filter names while its Focus is on, else the Space last used, switching there in each case, with a
    /// toast that says which (and notes a Focus). Edit Space says when a Focus filter sends links to it
    /// (`BrowserState.focusFilterGroup`, given the Focus filter's Space as the store has it). With only
    /// Home none of it shows.
    ///
    /// The share extension is `TestBrowser.share`; the system starting or ending a Focus with the
    /// filter is `focusFilter.set`, as `SpaceFocusFilter.perform()` does. Toasts are checked as soon as
    /// they're up, before their five seconds can run out.
    @Suite("Links from other apps")
    @MainActor
    struct LinksFromOtherAppsTests {
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

        /// A shared link with a Space picked opens there, switching to it, and the toast names it; a
        /// Space that no longer exists (here, an unknown name, so no Space at all) opens where links go
        /// anyway.
        @Test func sharedLinkOpensInTheSpacePicked() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))

            try browser.share(server.url.appending(path: "shared"), toSpaceNamed: "Projects")
            #expect(browser.store.state.activeSpace.name == "Projects", "the shared link didn't open in Projects")
            #expect(browser.store.activeTab?.url?.path() == "/shared")
            #expect(browser.store.tabs.count == 2, "Projects doesn't have the shared link")
            let toast = try #require(browser.store.toast, "no toast for the shared link")
            #expect(toast.message == "Opened in Projects", "the toast doesn't name Projects")
            #expect(toast.note == nil, "a Focus note with no Focus filter")
            #expect(toast.allActions.map(\.title) == ["Move…"], "no Move… for the shared link")
            #expect(browser.store.toastsShown == 1)
            try await browser.waitForPage("/shared")

            try browser.share(server.url.appending(path: "unpicked"), toSpaceNamed: "Gone")
            #expect(browser.store.toastsShown == 2, "no toast for the second link")
            #expect(browser.store.toast?.message == "Opened in Projects", "it didn't open in the Space last used")
            #expect(browser.store.state.activeSpace.name == "Projects")
            #expect(browser.store.activeTab?.url?.path() == "/unpicked")
            try await browser.waitForPage("/unpicked")
            withExtendedLifetime(server) {}
        }

        /// While a Focus filter names Work, links from other apps open there, with "Focus" on the toast; a
        /// Space picked in the share sheet still wins. Once the Focus ends, links open in the Space last
        /// used.
        @Test func focusFilterSendsLinksToItsSpaceUntilItEnds() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))

            let work = try browser.spaceID(named: "Work")
            browser.store.focusFilter.set(work)
            browser.openFromAnotherApp(server.url.appending(path: "focused"))
            #expect(browser.store.state.activeSpace.name == "Work", "the link didn't open in the Focus filter's Space")
            #expect(browser.store.activeTab?.url?.path() == "/focused")
            #expect(browser.store.toastsShown == 1, "no toast for the link")
            #expect(browser.store.toast?.message == "Opened in Work", "the toast doesn't name Work")
            #expect(browser.store.toast?.note?.text == "Focus", "the toast doesn't say a Focus chose Work")
            try await browser.waitForPage("/focused")

            try browser.share(server.url.appending(path: "picked"), toSpaceNamed: "Projects")
            #expect(browser.store.toastsShown == 2, "no toast for the shared link")
            #expect(browser.store.toast?.message == "Opened in Projects", "the Space picked didn't win")
            #expect(browser.store.toast?.note == nil, "a Focus note on a link the share sheet placed")
            #expect(browser.store.state.activeSpace.name == "Projects")
            try await browser.waitForPage("/picked")

            // The Focus ends: back to the Space last used (Projects, where the last link took you).
            browser.store.focusFilter.set(nil)
            browser.openFromAnotherApp(server.url.appending(path: "after"))
            #expect(browser.store.toastsShown == 3, "no toast for the link after the Focus")
            #expect(browser.store.state.activeSpace.name == "Projects", "the link didn't open in the Space last used")
            #expect(browser.store.toast?.message == "Opened in Projects", "the toast doesn't name Projects")
            #expect(browser.store.toast?.note == nil, "a Focus note after the Focus ended")
            try await browser.waitForPage("/after")
            withExtendedLifetime(server) {}
        }

        /// The filter's Space is still there after the app is killed and launched again.
        @Test func focusFilterSurvivesARelaunch() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            let work = try browser.spaceID(named: "Work")
            browser.store.focusFilter.set(work)

            try await browser.relaunch()
            try await browser.waitForPage("/a")
            #expect(browser.store.focusFilter.spaceID == work, "the relaunch lost the Focus filter's Space")
            browser.openFromAnotherApp(server.url.appending(path: "focused"))
            #expect(browser.store.state.activeSpace.name == "Work",
                    "after a relaunch the link didn't open in the Focus filter's Space")
            #expect(browser.store.toast?.note?.text == "Focus", "no Focus note after a relaunch")
            try await browser.waitForPage("/focused")
            withExtendedLifetime(server) {}
        }

        /// Edit Space says when the Focus filter sends links to this Space, and otherwise how to set it up.
        @Test func editSpaceShowsTheFocusFilter() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            let work = try browser.spaceID(named: "Work"), projects = try browser.spaceID(named: "Projects")
            browser.store.focusFilter.set(work)

            let workGroup = try #require(focusGroup(editing: work, named: "Work", in: browser), "Edit Space has no Focus group")
            #expect(workGroup.isOn)
            #expect(workGroup.status == "On now: links from other apps open in Work")
            #expect(workGroup.footer == "When the Focus ends, links open in the last Space you used.",
                    "no word on what happens when the Focus ends")

            let projectsGroup = try #require(focusGroup(editing: projects, named: "Projects", in: browser),
                                             "Projects' Edit Space has no Focus group")
            #expect(!projectsGroup.isOn)
            #expect(projectsGroup.status == "Off")
            #expect(projectsGroup.footer == "To open links from other apps in Projects during a Focus, go to Settings › Focus, choose a Focus, then Add Filter › Cormorant › Projects.",
                    "no word on setting up a Focus filter")
            withExtendedLifetime(server) {}
        }

        /// With only Home nothing new shows: a link the Focus filter or the share sheet sends to Home opens
        /// with no toast, and Edit Space has no Focus group.
        @Test func oneSpaceShowsNothingNew() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))

            browser.store.focusFilter.set(Space.defaultID)
            browser.openFromAnotherApp(server.url.appending(path: "focused"))
            #expect(browser.store.activeTab?.url?.path() == "/focused", "the link didn't open")
            try await browser.waitForPage("/focused")
            try browser.share(server.url.appending(path: "shared"), toSpaceNamed: "Home")
            #expect(browser.store.activeTab?.url?.path() == "/shared", "the shared link didn't open")
            try await browser.waitForPage("/shared")
            #expect(browser.store.toast == nil, "a toast with only Home")
            #expect(browser.store.toastsShown == 0, "a toast came and went with only Home")
            #expect(browser.store.tabs.count == 3)

            #expect(focusGroup(editing: Space.defaultID, named: "Home", in: browser) == nil, "a Focus group with only Home")
            withExtendedLifetime(server) {}
        }

        /// Its toast's Move… acts on the link's tab, so the toast comes down when the tab closes (a back
        /// swipe, `BrowserStore.close`), not left up with a button that would do nothing.
        @Test func closingTheLinksTabTakesItsToastDown() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(state: seededSpaces(server.url))
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))

            browser.openFromAnotherApp(server.url.appending(path: "linked"))
            let toast = try #require(browser.store.toast, "no toast for the link")
            #expect(toast.allActions.map(\.title) == ["Move…"], "no Move… for the link")
            let linked = try #require(browser.store.activeTab?.id)
            #expect(toast.tabID == linked)
            // Kept up while the page loads, as VoiceOver on it would: it must go with the tab, not its time.
            browser.store.holdToast(true)
            try await browser.waitForPage("/linked")
            #expect(browser.store.toast?.id == toast.id, "the toast went before the tab closed")

            browser.store.close(linked)
            #expect(browser.store.toast == nil, "the toast stayed up for a closed tab")
            #expect(browser.store.activeTab?.url?.path() == "/a", "closing the link's tab didn't go back to /a")
            try await browser.waitForPage("/a")
            withExtendedLifetime(server) {}
        }

        // MARK: Helpers

        /// What Edit Space shows in its Focus group for the Space, with the name as saved in the field.
        private func focusGroup(editing spaceID: UUID, named name: String, in browser: TestBrowser) -> FocusFilterGroup? {
            browser.store.state.focusFilterGroup(editing: spaceID, named: name, focusSpace: browser.store.focusFilter.spaceID)
        }

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
}
