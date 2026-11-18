import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
@testable import Cormorant

extension AppTests {
    /// Settings' Archive Idle Tabs: the switch turns auto-archive off for every Space at once and back on
    /// with each Space's own time, Off keeps idle tabs open, and both survive a relaunch. What the
    /// switch, the time and the footer show comes from `TabsSettings`' own functions.
    @Suite("Archive Idle Tabs")
    @MainActor
    struct ArchiveIdleTabsTests {
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1>Fixture</h1>
            """

        /// Two days, past the 24-hour default.
        private static let twoDays: TimeInterval = 2 * 24 * 60 * 60

        @Test func offStaysOffAfterRelaunchAndOnComesBackAtItsTime() async throws {
            let browser = try await TestBrowser()
            defer { browser.close() }
            #expect(browser.store.state.archivesIdleTabs, "auto-archive isn't on by default")
            #expect(TabsSettings.timesSummary(browser.store.state) == "24 Hours")

            browser.store.setArchivesIdleTabs(false)
            #expect(!browser.store.state.archivesIdleTabs)
            // Dimmed, with the time that comes back.
            #expect(TabsSettings.timesSummary(browser.store.state) == "24 Hours")
            #expect(TabsSettings.footer(browser.store.state, opening: nil, now: .now) == "Tabs stay open until you close them.")

            try await browser.relaunch()
            #expect(!browser.store.state.archivesIdleTabs, "Off didn't stick")

            browser.store.setArchivesIdleTabs(true)
            #expect(browser.store.state.archivesIdleTabs)
            #expect(browser.store.state.activeSpace.archivePolicy == .oneDay, "the time didn't come back")
        }

        /// Arc's four times are offered beside the switch (Off is the switch, not a time); 7 Days sticks.
        @Test func sevenDaysStaysAfterRelaunch() async throws {
            let browser = try await TestBrowser()
            defer { browser.close() }
            #expect(ArchivePolicy.choices(keeping: .oneDay).filter { $0 != .off }.map(\.label)
                == ["12 Hours", "24 Hours", "7 Days", "30 Days"])

            browser.store.setArchivePolicy(.sevenDays, forSpace: browser.store.state.activeSpaceID)
            #expect(TabsSettings.timesSummary(browser.store.state) == "7 Days")

            try await browser.relaunch()
            #expect(TabsSettings.timesSummary(browser.store.state) == "7 Days", "the time didn't stick")
        }

        /// With archiving off, a tab idle two days is still open at the next launch; turned back on, the
        /// footer says it will move, and at the next launch it has.
        @Test func offKeepsAnIdleTab() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "a"))
            try await browser.open(server.url.appending(path: "b"), inNewTab: true)
            #expect(browser.store.tabs.count == 2)

            browser.store.setArchivesIdleTabs(false)
            // /a, in the background, was last looked at two days ago.
            try await browser.relaunch(idleFor: Self.twoDays)
            #expect(browser.store.tabs.count == 2, "Off archived the idle tab")

            // Settings opens with archiving off, then the switch goes on.
            let opening = Dictionary(uniqueKeysWithValues: browser.store.state.spaces.map { ($0.id, $0.archivePolicy) })
            browser.store.setArchivesIdleTabs(true)
            #expect(TabsSettings.footer(browser.store.state, opening: opening, now: .now)
                == "Tabs you haven't looked at for this long move to the tab archive. 1 tab has been idle longer than that, and will move the next time you come back to Cormorant.")

            try await browser.relaunch(idleFor: Self.twoDays)
            #expect(browser.store.tabs.count == 1, "the idle tab didn't archive once on")
            #expect(browser.store.state.archived.map { $0.url.path() } == ["/a"])
        }

        /// Off turns every Space off at once; on gives each its own time back, Off included, and a time
        /// this build doesn't offer (Trips' 3 days) too.
        @Test func severalSpacesTurnOffTogetherAndComeBackAsTheyWere() async throws {
            var state = BrowserState.empty
            let times: [(String, ArchivePolicy)] = [("Work", .twelveHours), ("Reading", .off),
                                                     ("Trips", ArchivePolicy(interval: 3 * 24 * 60 * 60))]
            for (name, policy) in times {
                let space = state.addSpace(name: name)
                state.updateSpace(space.id) { $0.archivePolicy = policy }
            }
            let browser = try await TestBrowser(state: state)
            defer { browser.close() }
            let expected = ["Home": "24 Hours", "Work": "12 Hours", "Reading": "Off", "Trips": "3 Days"]
            #expect(TabsSettings.timesSummary(browser.store.state) == "Varies")
            #expect(TabsSettings.footer(browser.store.state, opening: nil, now: .now).hasSuffix("Spaces never archive on their own."))
            #expect(labels(browser.store.state) == expected)

            browser.store.setArchivesIdleTabs(false)
            #expect(!browser.store.state.archivesIdleTabs)
            #expect(TabsSettings.timesSummary(browser.store.state) == "Varies", "the times that come back changed")
            #expect(TabsSettings.footer(browser.store.state, opening: nil, now: .now)
                == "Tabs in every Space stay open until you close them. Spaces never archive on their own.")

            try await browser.relaunch()
            #expect(!browser.store.state.archivesIdleTabs, "Off didn't stick")

            browser.store.setArchivesIdleTabs(true)
            #expect(labels(browser.store.state) == expected)
        }

        private func labels(_ state: BrowserState) -> [String: String] {
            Dictionary(uniqueKeysWithValues: state.switchableSpaces.map { ($0.name, $0.archivePolicy.label) })
        }
    }
}
