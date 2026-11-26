import CormorantCore
import CormorantSync
import CormorantTestSupport
import Foundation
import Testing
import WebKit
@testable import Cormorant
@testable import CormorantBrowser

extension AppTests {
    /// Two browsers on one cloud are one person's phone and Mac: what one does to Spaces and tabs the
    /// other does too, an unreadable state file is neither sent nor merged into, and nothing of
    /// Incognito leaves the device. The cloud is `FakeSyncCloud` (CloudKit can't run here); the merge
    /// itself is tested in CormorantKit's CormorantSyncTests. Settings' switch and status stay in
    /// CormorantUITests.
    @Suite("Sync")
    @MainActor
    struct SyncTests {
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <p>Page</p>
            <script>document.title = 'Page ' + location.pathname.slice(1)</script>
            """

        let cloud = FakeSyncCloud()
        let keys = FakeSyncKeyStore()

        private func device(state: BrowserState? = nil, savedFile: Data? = nil) async throws -> TestBrowser {
            try await TestBrowser(state: state, savedFile: savedFile, sync: (cloud, keys))
        }

        @Test func aTabOpenedOnOneDeviceIsOnTheOtherAndClosingItThereClosesItHere() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            let mac = try await device()
            defer { mac.close() }

            try await phone.open(server.url.appending(path: "a"))
            let tab = try #require(phone.store.activeTab)
            try await phone.until("the page's title") { phone.store.activeTab?.title == "Page a" }
            await phone.syncNow()
            await mac.syncNow()
            #expect(mac.store.state.tabs.map(\.id) == [tab.id])
            #expect(mac.store.state.tab(tab.id)?.title == "Page a")

            // It loads there when it's shown.
            mac.store.activate(tab.id)
            try await mac.waitForPage("/a")

            mac.store.close(tab.id)
            await mac.syncNow()
            await phone.syncNow()
            #expect(phone.store.state.tabs.isEmpty)
            #expect(phone.store.activeSession == nil)
            #expect(phone.store.state.archived.map(\.id) == [tab.id])
            #expect(phone.store.sync?.state == .idle)
        }

        @Test func aTabThatWentElsewhereOnTheOtherDeviceLoadsThatPageWhenShown() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            let mac = try await device()
            defer { mac.close() }

            try await phone.open(server.url.appending(path: "a"))
            let tab = try #require(phone.store.activeTab)
            await phone.syncNow()
            await mac.syncNow()
            mac.store.activate(tab.id)
            try await mac.waitForPage("/a")
            // Another tab in front on the Mac.
            try await mac.open(server.url.appending(path: "other"), inNewTab: true)

            try await phone.open(server.url.appending(path: "b"))
            #expect(phone.store.activeTab?.id == tab.id)
            await phone.syncNow()
            await mac.syncNow()
            #expect(mac.store.state.tab(tab.id)?.url?.path() == "/b")
            mac.store.activate(tab.id)
            try await mac.waitForPage("/b")
            // Its old history went with the old page: there's no going back to /a on this device.
            #expect(mac.store.activeSession?.webView.canGoBack == false)
        }

        @Test func theTabBeingLookedAtStaysOnItsPageUntilTheAppIsLeft() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            let mac = try await device()
            defer { mac.close() }

            try await phone.open(server.url.appending(path: "a"))
            let tab = try #require(phone.store.activeTab)
            await phone.syncNow()
            await mac.syncNow()
            mac.store.activate(tab.id)
            try await mac.waitForPage("/a")

            try await phone.open(server.url.appending(path: "b"))
            await phone.syncNow()
            await mac.syncNow()
            // Not pulled away from under the reader.
            #expect(mac.store.activeSession?.webView.url?.path() == "/a")
            #expect(mac.store.state.tab(tab.id)?.url?.path() == "/b")
            // And staying there isn't sent back as a change.
            await mac.syncNow()
            await phone.syncNow()
            #expect(phone.store.state.tab(tab.id)?.url?.path() == "/b")

            mac.store.didEnterBackground()
            mac.store.didBecomeActive()
            try await mac.waitForPage("/b")
        }

        @Test func anUnreadableStateFileIsNeitherSentNorMergedInto() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            try await phone.open(server.url.appending(path: "a"))
            await phone.syncNow()
            let stored = await cloud.stored

            let mac = try await device(savedFile: Data("not a state file".utf8))
            defer { mac.close() }
            #expect(mac.store.loadFailure != nil)
            await mac.syncNow()
            #expect(mac.store.sync?.isOn == false)
            #expect(mac.store.state.tabs.isEmpty)
            #expect(await cloud.stored == stored)
            let files = try FileManager.default.contentsOfDirectory(atPath: mac.directory.path())
            #expect(files.contains { $0.contains("corrupt") })
            #expect(!files.contains("state.json"))

            // Start Fresh: it joins as a new device, taking nothing away from the phone.
            mac.store.startFresh()
            await mac.syncNow()
            await phone.syncNow()
            #expect(mac.store.state.tabs.map(\.url) == phone.store.state.tabs.map(\.url))
            #expect(phone.store.state.tabs.count == 1)
        }

        @Test func nothingOfIncognitoLeavesTheDevice() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            let mac = try await device()
            defer { mac.close() }

            try await phone.open(server.url.appending(path: "home"))
            await phone.syncNow()
            let before = await cloud.stored.count
            phone.store.newTab()
            phone.store.setComposesIncognito(true)
            try await phone.open(server.url.appending(path: "secret"))
            #expect(phone.store.activeTab?.isIncognito == true)
            await phone.syncNow()
            await mac.syncNow()
            #expect(mac.store.state.tabs.compactMap { $0.url?.path() } == ["/home"])
            #expect(await cloud.stored.count == before)

            // A change from the Mac doesn't disturb it.
            try await mac.open(server.url.appending(path: "mac"), inNewTab: true)
            await mac.syncNow()
            await phone.syncNow()
            #expect(phone.store.activeTab?.isIncognito == true)
            #expect(phone.store.activeSession?.webView.url?.path() == "/secret")
            #expect(phone.store.state.shared.tabs.count == 2)
        }

        /// A tab that looks idle here may have been used on the other device all day: with sync on,
        /// idle tabs only archive once a round has brought the other devices' news.
        @Test func idleTabsWaitForSyncBeforeTheyArchive() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            try await phone.open(server.url.appending(path: "a"))
            // A second tab in front: the tab on screen never archives.
            try await phone.open(server.url.appending(path: "b"), inNewTab: true)
            await phone.syncNow()

            await cloud.fail(with: .failed("offline"))
            try await phone.relaunch(idleFor: 3 * 86_400)
            await phone.syncNow()
            #expect(phone.store.sync?.state == .failed("offline"))
            #expect(phone.store.state.tabs.count == 2)
            #expect(phone.store.state.archived.isEmpty)

            await cloud.fail(with: nil)
            phone.store.didBecomeActive()
            try await phone.until("the idle tab to archive once sync has run") { phone.store.state.archived.count == 1 }
            #expect(phone.store.state.tabs.compactMap { $0.url?.path() } == ["/b"])
        }

        @Test func startingFreshDoesNotReadTheOldSession() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            let mac = try await device()
            defer { mac.close() }
            try await phone.open(server.url.appending(path: "kept"))
            try await phone.open(server.url.appending(path: "closed-later"), inNewTab: true)
            let closedLater = try #require(phone.store.activeTab)
            await phone.syncNow()
            await mac.syncNow()
            #expect(mac.store.state.tabs.count == 2)

            // The phone goes away with its session on disk; the Mac closes a tab and empties its archive.
            phone.store.didEnterBackground()
            try await phone.waitForSaves()
            await phone.store.sync?.finish()
            let stateFile = phone.directory.appending(path: "state.json")
            phone.store.terminateForTesting()
            mac.store.close(closedLater.id)
            mac.store.clearArchive()
            await mac.syncNow()

            // Its state file is unreadable at the next launch, and it starts fresh.
            try Data("not a state file".utf8).write(to: stateFile)
            try await phone.relaunch(skippingSave: true)
            #expect(phone.store.loadFailure != nil)
            phone.store.startFresh()
            await phone.syncNow()
            await mac.syncNow()
            #expect(phone.store.state.tabs.compactMap { $0.url?.path() } == ["/kept"])
            #expect(mac.store.state.tabs.compactMap { $0.url?.path() } == ["/kept"])
            #expect(mac.store.state.archived.isEmpty)
        }

        @Test func whatWasClosedOfflineIsStillClosedAfterARelaunch() async throws {
            let server = try FixtureServer(html: Self.page)
            let phone = try await device()
            defer { phone.close() }
            let mac = try await device()
            defer { mac.close() }

            try await phone.open(server.url.appending(path: "a"))
            let tab = try #require(phone.store.activeTab)
            await phone.syncNow()
            await mac.syncNow()

            await cloud.fail(with: .failed("offline"))
            phone.store.close(tab.id)
            await phone.syncNow()
            try await phone.relaunch()
            await cloud.fail(with: nil)
            await phone.syncNow()
            await mac.syncNow()
            #expect(phone.store.state.tabs.isEmpty)
            #expect(mac.store.state.tabs.isEmpty)
        }
    }
}
