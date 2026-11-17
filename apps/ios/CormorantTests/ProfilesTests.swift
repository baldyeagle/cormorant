import CormorantCore
import Foundation
import Testing
import WebKit
@testable import Cormorant

extension AppTests {
    /// Profiles keep website data apart: a cookie set in one profile isn't seen in another, and the
    /// search panel's history comes from the active Space's profile only. Deleting a profile moves its
    /// Spaces to Default, whose website data their tabs then load with, and erases its website data
    /// store and history, for good. Making profiles, the profile picker and the confirmations stay in
    /// CormorantUITests' ProfilesTests.
    @Suite("Profiles")
    @MainActor
    struct ProfilesTests {
        /// Every path serves this page. It names its path, sets the cookie `probe` to whatever follows
        /// `/set/`, and shows the `probe` this profile's website data has.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <p id="cookie">Cookie</p>
            <script>
              const set = location.pathname.match(/^\\/set\\/(\\w+)$/)
              if (set) document.cookie = 'probe=' + set[1] + '; path=/; max-age=86400'
              const probe = document.cookie.split('; ').find(c => c.startsWith('probe='))
              document.getElementById('path').textContent = 'Path ' + location.pathname
              document.getElementById('cookie').textContent = 'Cookie ' + (probe || 'none')
              document.title = 'Page ' + location.pathname.slice(1)
            </script>
            """

        /// Past WebKit letting go of a deleted profile's store (seconds to most of a minute on CI) and
        /// the whole of the app's retries (`BrowserStore.profileErasureWaits`, about two minutes), within
        /// the root suite's three minutes a test.
        private static let erasureCeiling: Duration = .seconds(150)

        @Test func cookiesStayInTheirProfile() async throws {
            let server = try FixtureServer(html: Self.page)
            let seeded = Seeded(server.url)
            let browser = try await TestBrowser(state: seeded.state)
            defer { browser.close() }
            let home = Self.token(), work = Self.token()
            try await browser.open(server.url.appending(path: "set/\(home)"))
            #expect(try await browser.cookieShown() == "Cookie probe=\(home)", "Home's cookie wasn't set")

            // Work is on Vialumi: Home's cookie isn't there.
            browser.store.switchToSpace(seeded.work)
            #expect(browser.store.activeProfileID == seeded.vialumi)
            try await browser.waitForPage("/work")
            #expect(try await browser.cookieShown() == "Cookie none", "Work sees Home's cookie")
            try await browser.open(server.url.appending(path: "set/\(work)"))
            #expect(try await browser.cookieShown() == "Cookie probe=\(work)", "Work's cookie wasn't set")

            // And Work's isn't in Default: Home still has its own.
            browser.store.switchToSpace(Space.defaultID)
            try await browser.open(server.url.appending(path: "check"))
            #expect(try await browser.cookieShown() == "Cookie probe=\(home)", "Home's cookie changed")
            withExtendedLifetime(server) {}
        }

        /// Deleting Vialumi moves Work to Default, its tab loading again with Default's cookies, and
        /// erases Vialumi's website data store and history while the app runs; a relaunch finds it
        /// still gone, with nothing left to erase.
        @Test func deletingAProfileMovesItsSpacesToDefaultAndErasesItsData() async throws {
            let server = try FixtureServer(html: Self.page)
            let seeded = Seeded(server.url)
            let vialumi = seeded.vialumi
            let browser = try await TestBrowser(state: seeded.state)
            defer { browser.close() }
            let home = Self.token(), work = Self.token()
            try await browser.open(server.url.appending(path: "set/\(home)"))
            #expect(try await browser.cookieShown() == "Cookie probe=\(home)", "Home's cookie wasn't set")

            // Work, on Vialumi: a cookie and history of its own, in a second tab, left on /check.
            browser.store.switchToSpace(seeded.work)
            try await browser.waitForPage("/work")
            #expect(try await browser.cookieShown() == "Cookie none", "Work sees Home's cookie")
            try await browser.open(server.url.appending(path: "set/\(work)"), inNewTab: true)
            try await browser.open(server.url.appending(path: "check"))
            #expect(try await browser.cookieShown() == "Cookie probe=\(work)", "Work's cookie wasn't set")
            let storesBefore = await WKWebsiteDataStore.allDataStoreIdentifiers
            #expect(storesBefore.contains(vialumi), "Vialumi has no website data store to erase")
            let historyBefore = try await browser.historyProfiles()
            #expect(historyBefore.contains(vialumi), "Vialumi has no history to erase")

            browser.store.deleteProfile(vialumi)
            #expect(browser.store.state.profile(vialumi) == nil, "Vialumi is still listed")
            #expect(browser.store.state.profile(forSpace: seeded.work).isDefault, "Work isn't on Default")
            #expect(browser.store.state.profilesToErase == [vialumi])
            // Work's tab loads again, with Default's website data.
            #expect(browser.store.activeSession?.profileID == Profile.defaultID, "Work's tab isn't on Default")
            try await browser.waitForPage("/check")
            #expect(try await browser.cookieShown() == "Cookie probe=\(home)", "Work's tab isn't on Default's data")

            // Erased once WebKit lets go of the store, with no web view left on it.
            try await browser.until("Vialumi's data to be erased (still to erase: \(browser.store.state.profilesToErase))",
                                    within: Self.erasureCeiling) {
                browser.store.state.profilesToErase.isEmpty
            }
            let storesAfter = await WKWebsiteDataStore.allDataStoreIdentifiers
            #expect(!storesAfter.contains(vialumi), "Vialumi's website data store is still there")
            let historyAfter = try await browser.historyProfiles()
            #expect(!historyAfter.contains(vialumi), "Vialumi's history is still there")

            // And it stays so: the relaunch is back in Work, on Default, with nothing to erase.
            try await browser.relaunch()
            #expect(browser.store.state.profiles.map(\.id) == [Profile.defaultID])
            #expect(browser.store.state.profilesToErase.isEmpty, "Vialumi is to erase again")
            #expect(browser.store.state.activeSpaceID == seeded.work)
            #expect(browser.store.state.profile(forSpace: seeded.work).isDefault, "Work isn't on Default")
            try await browser.waitForPage("/check")
            #expect(try await browser.cookieShown() == "Cookie probe=\(home)", "Work's tab isn't on Default's data")
            let storesRelaunched = await WKWebsiteDataStore.allDataStoreIdentifiers
            #expect(!storesRelaunched.contains(vialumi), "Vialumi's website data store came back")
            withExtendedLifetime(server) {}
        }

        /// What the search panel suggests from (`BrowsingHistory.pages(matching:profile:)` for the active
        /// profile): in Work, Vialumi's pages; in Home, Default's.
        @Test func historyFollowsTheProfile() async throws {
            let server = try FixtureServer(html: Self.page)
            let seeded = Seeded(server.url)
            let browser = try await TestBrowser(state: seeded.state)
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "alpha"))
            browser.store.switchToSpace(seeded.work)
            try await browser.waitForPage("/work")
            try await browser.open(server.url.appending(path: "beta"))

            // In Work, Vialumi's history: beta, not alpha.
            #expect(browser.store.activeProfileID == seeded.vialumi)
            #expect(try await browser.historyPaths(matching: "beta") == ["/beta"], "Work's history doesn't have beta")
            #expect(try await browser.historyPaths(matching: "alpha") == [], "Work suggests Home's history")

            // In Home, Default's: alpha, not beta.
            browser.store.switchToSpace(Space.defaultID)
            #expect(browser.store.activeProfileID == Profile.defaultID)
            #expect(try await browser.historyPaths(matching: "alpha") == ["/alpha"], "Home's history doesn't have alpha")
            #expect(try await browser.historyPaths(matching: "beta") == [], "Home suggests Work's history")
            withExtendedLifetime(server) {}
        }

        /// What the UI tests' `-uiTestingSpaces` seeds: Work, on a profile of its own (Vialumi), and Projects,
        /// with one tab each at `<base>/work` and `<base>/projects`, and an empty Trip, beside an empty Home,
        /// which is active.
        private struct Seeded {
            var state = BrowserState.empty
            let vialumi: UUID
            let work: UUID
            let projects: UUID
            let trip: UUID

            init(_ base: URL) {
                vialumi = state.addProfile(name: "Vialumi", color: .indigo).id
                work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo, profileID: vialumi).id
                projects = state.addSpace(name: "Projects", icon: .hammer, color: .orange).id
                _ = state.openTab(url: base.appending(path: "work"), inSpace: work, activate: false)
                _ = state.openTab(url: base.appending(path: "projects"), inSpace: projects, activate: false)
                trip = state.addSpace(name: "Trip", icon: .airplane, color: .green).id
            }
        }

        /// A cookie value no earlier run can have left in the default profile's website data, which
        /// every test in the process (and every run on the simulator) shares.
        private static func token() -> String { "t" + UUID().uuidString.prefix(8).lowercased() }
    }
}

fileprivate extension TestBrowser {
    /// The page on screen's report of its `probe` cookie, as it found it loading: "Cookie probe=<value>"
    /// or "Cookie none".
    func cookieShown() async throws -> String? {
        try await evaluate("document.getElementById('cookie').textContent")
    }

    /// The profiles with history, once every visit so far is written.
    func historyProfiles() async throws -> Set<UUID> {
        try #require(await store.afterBrowsingHistoryWrites { await $0.profiles() }, "no history database")
    }

    /// The paths of the pages the search panel would suggest for `text` from the active Space's
    /// profile's history, once every visit so far is written.
    func historyPaths(matching text: String) async throws -> [String] {
        let profile = store.activeProfileID
        let pages = try #require(await store.afterBrowsingHistoryWrites { await $0.pages(matching: text, profile: profile) },
                                 "no history database")
        return pages.map { $0.url.path() }
    }
}
