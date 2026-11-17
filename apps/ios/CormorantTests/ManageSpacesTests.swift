import CormorantCore
import Foundation
import Testing
@testable import Cormorant

extension AppTests {
    /// What Manage Spaces and Edit Space change: Home renamed, never archived or deleted; archiving keeps
    /// a Space and its tabs for Restore; deleting sends its tabs to the tab archive; each survives a
    /// relaunch. The confirmations' text (`Space.archiveConfirmation`, `deleteConfirmation`) is tested in
    /// CormorantKit; the forms, the checkmark and the Archived section's swipe stay in CormorantUITests'
    /// ManageSpacesTests.
    @Suite("Manage Spaces")
    @MainActor
    struct ManageSpacesTests {
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

        @Test func renamingHomeAndNoArchiveOrDelete() async throws {
            let browser = try await TestBrowser()
            defer { browser.close() }
            let home = browser.store.state.activeSpace
            #expect(home.id == Space.defaultID)

            // As Edit Space's Save does, with the name as typed.
            browser.store.updateSpace(home.id, name: " Personal ", icon: home.icon, color: home.color,
                                      archivePolicy: home.archivePolicy, profileID: home.profileID)
            #expect(browser.store.state.switchableSpaces.map(\.name) == ["Personal"], "Home wasn't renamed")

            // Home always exists: neither archived nor deleted, whoever asks.
            browser.store.archiveSpace(home.id)
            browser.store.deleteSpace(home.id)
            #expect(browser.store.state.spaces.map(\.id) == [Space.defaultID], "Home went")
            #expect(browser.store.state.archivedSpaces.isEmpty, "Home was archived")

            try await browser.relaunch()
            #expect(browser.store.state.switchableSpaces.map(\.name) == ["Personal"], "the new name didn't stick")
        }

        /// Archiving the Space you're in goes back to Home; the Space leaves switching, keeping its tab but
        /// not its page, until Restore brings it back where it was, without switching to it.
        @Test func archivingAndRestoringASpace() async throws {
            let server = try FixtureServer(html: Self.page)
            var state = BrowserState.empty
            let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo).id
            let browser = try await TestBrowser(state: state)
            defer { browser.close() }
            browser.store.switchToSpace(work)
            try await browser.open(server.url.appending(path: "work"))

            browser.store.archiveSpace(work)
            #expect(browser.store.state.activeSpaceID == Space.defaultID, "archiving the Space you're in didn't go to Home")
            #expect(browser.store.activeSession == nil, "Home has a tab on screen")
            #expect(browser.store.state.switchableSpaces.map(\.id) == [Space.defaultID], "Work is still in the list")
            #expect(browser.store.state.archivedSpaces.map(\.id) == [work], "Work isn't under Archived")
            #expect(!browser.store.hasSpacesToSwitch)
            #expect(paths(browser.store.state.tabs(inSpace: work)) == ["/work"], "Work's tab wasn't kept")
            #expect(!browser.store.hasWebViews(usingProfile: Profile.defaultID), "Work's page is still running")

            try await browser.relaunch()
            #expect(browser.store.state.archivedSpaces.map(\.id) == [work], "Work isn't archived after a relaunch")

            browser.store.restoreSpace(work)
            #expect(browser.store.state.switchableSpaces.map(\.id) == [Space.defaultID, work], "Restore didn't bring Work back")
            #expect(browser.store.state.archivedSpaces.isEmpty, "Work is still under Archived")
            #expect(browser.store.state.activeSpaceID == Space.defaultID, "Restore switched to Work")
            #expect(paths(browser.store.state.tabs(inSpace: work)) == ["/work"], "Work's tab didn't come back with it")

            // Archived again and deleted from Archived, without restoring it first: gone, its tab to the
            // tab archive.
            browser.store.archiveSpace(work)
            browser.store.deleteSpace(work)
            #expect(browser.store.state.space(work) == nil, "Work is still there")
            #expect(browser.store.state.archivedSpaces.isEmpty, "Work is still under Archived")
            #expect(browser.store.state.archived.map { $0.url.path() } == ["/work"], "Work's tab isn't in the tab archive")
            withExtendedLifetime(server) {}
        }

        /// Deleting the Space you're in goes back to Home, empty; its tab goes to the tab archive, where
        /// it's found from Home (it reopens there, its Space gone).
        @Test func deletingASpaceSendsItsTabsToTheArchive() async throws {
            let server = try FixtureServer(html: Self.page)
            var state = BrowserState.empty
            let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo).id
            let browser = try await TestBrowser(state: state)
            defer { browser.close() }
            browser.store.switchToSpace(work)
            try await browser.open(server.url.appending(path: "work"))
            try await browser.until("the tab's title") { browser.store.activeTab?.title == "Tab /work" }

            browser.store.deleteSpace(work)
            #expect(browser.store.state.space(work) == nil, "Work is still listed")
            #expect(browser.store.state.switchableSpaces.map(\.id) == [Space.defaultID])
            // Back in Home, empty.
            #expect(browser.store.state.activeSpaceID == Space.defaultID, "Home isn't the current Space")
            #expect(browser.store.activeTab == nil && browser.store.activeSession == nil, "Home isn't empty")
            #expect(browser.store.tabs.isEmpty, "Home isn't empty")
            #expect(browser.store.state.tabs.isEmpty, "Work's tab is still open")
            let archived = browser.store.state.archived
            #expect(archived.map { $0.url.path() } == ["/work"], "Work's tab isn't in the tab archive")
            #expect(archived.map(\.title) == ["Tab /work"])
            #expect(browser.store.state.archived(reopeningIn: Space.defaultID).map(\.id) == archived.map(\.id),
                    "Work's tab doesn't reopen in Home")

            try await browser.relaunch()
            #expect(browser.store.state.space(work) == nil, "Work came back")
            #expect(browser.store.state.archived.map { $0.url.path() } == ["/work"], "the tab archive changed")
            withExtendedLifetime(server) {}
        }

        private func paths(_ tabs: [CormorantCore.Tab]) -> [String?] {
            tabs.map { $0.url?.path() }
        }
    }
}
