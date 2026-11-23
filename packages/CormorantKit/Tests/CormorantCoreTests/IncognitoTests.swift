import Foundation
import Testing
@testable import CormorantCore

@Suite struct IncognitoTests {
    /// Home with one tab viewed at t0, active.
    private func home() -> (BrowserState, Tab) {
        var state = BrowserState()
        let tab = state.openTab(url: url("https://home.example"), now: t0)
        return (state, tab)
    }

    @Test func incognitoExistsOnlyWhileItHasTabs() {
        var (state, _) = home()
        #expect(!state.isIncognitoOpen)
        #expect(state.space(Space.incognitoID) == nil)
        #expect(state.shownSpaces.map(\.id) == [Space.defaultID])
        #expect(!state.hasSpacesToSwitch)

        let tab = state.openIncognitoTab(url: url("https://private.example"), now: t0 + hour)
        #expect(state.isIncognitoOpen)
        #expect(state.space(Space.incognitoID)?.isIncognito == true)
        #expect(state.shownSpaces.map(\.id) == [Space.defaultID, Space.incognitoID])
        #expect(state.hasSpacesToSwitch)
        // Never among the Spaces you made.
        #expect(state.spaces.map(\.id) == [Space.defaultID])
        #expect(state.switchableSpaces.map(\.id) == [Space.defaultID])
        #expect(state.activeSpaceID == Space.incognitoID && state.activeTabID == tab.id)
        #expect(state.profile(forSpace: Space.incognitoID).id == Profile.incognitoID)
        #expect(state.profile(Profile.incognitoID) == nil)
    }

    @Test func closingTheLastIncognitoTabGoesBackToTheTabBefore() {
        var (state, homeTab) = home()
        var work = state.addSpace(name: "Work", now: t0)
        state.switchToSpace(work.id, now: t0)
        let workTab = state.openTab(url: url("https://work.example"), now: t0 + hour)
        work = state.space(work.id)!
        let first = state.openIncognitoTab(url: url("https://a.example"), now: t0 + 2 * hour)
        let second = state.openIncognitoTab(url: url("https://b.example"), now: t0 + 3 * hour)
        #expect(state.spaceBeforeIncognito == work.id)

        state.archive(tabID: second.id, now: t0 + 4 * hour)
        #expect(state.activeSpaceID == Space.incognitoID && state.activeTabID == first.id)
        state.archive(tabID: first.id, now: t0 + 5 * hour)
        #expect(!state.isIncognitoOpen)
        #expect(state.activeSpaceID == work.id && state.activeTabID == workTab.id)
        // Deleted, not archived.
        #expect(state.archived.isEmpty)
        #expect(Set(state.tabs.map(\.id)) == [homeTab.id, workTab.id])
    }

    @Test func closingTheLastIncognitoTabFromAnotherSpaceStaysThere() {
        var (state, homeTab) = home()
        let tab = state.openIncognitoTab(url: url("https://a.example"), activate: false, now: t0 + hour)
        #expect(state.activeSpaceID == Space.defaultID && state.isIncognitoOpen)
        state.archive(tabID: tab.id, now: t0 + 2 * hour)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == homeTab.id)
        #expect(state.archived.isEmpty)
    }

    @Test func goesBackHomeWhenTheSpaceBeforeIsGone() {
        var (state, homeTab) = home()
        let work = state.addSpace(name: "Work", now: t0)
        state.switchToSpace(work.id, now: t0)
        let tab = state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        state.deleteSpace(work.id, now: t0 + 2 * hour)
        #expect(state.activeSpaceID == Space.incognitoID)
        #expect(state.spaceOutsideIncognito == Space.defaultID)
        state.archive(tabID: tab.id, now: t0 + 3 * hour)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == homeTab.id)
    }

    @Test func newTabsInIncognitoStayThere() {
        var (state, _) = home()
        state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        // The + on an incognito tab, and a popup or link opened from one.
        let plus = state.openTab(url: url("https://b.example"), now: t0 + 2 * hour)
        let popup = state.openTab(url: url("https://c.example"), inSpace: Space.incognitoID, activate: false, now: t0 + 3 * hour)
        #expect(plus.isIncognito && popup.isIncognito)
        #expect(state.activeTabID == plus.id)
        // Named Incognito while it isn't the active Space, it opens there, in the background (as any
        // tab opened outside the active Space does).
        var other = BrowserState()
        let homeTab = other.openTab(url: url("https://home.example"), now: t0)
        let tab = other.openTab(url: url("https://d.example"), inSpace: Space.incognitoID, now: t0)
        #expect(tab.isIncognito && other.activeSpaceID == Space.defaultID && other.activeTabID == homeTab.id)
    }

    @Test func tabsDontMoveInOrOutOfIncognito() {
        var (state, homeTab) = home()
        let work = state.addSpace(name: "Work", now: t0)
        let tab = state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        #expect(state.moveTab(tab.id, toSpace: work.id, now: t0 + 2 * hour) == nil)
        #expect(state.moveTab(homeTab.id, toSpace: Space.incognitoID, now: t0 + 2 * hour) == nil)
        #expect(state.tab(tab.id)?.isIncognito == true && state.tab(homeTab.id)?.spaceID == Space.defaultID)
    }

    @Test func incognitoTabsNeverAutoArchive() {
        var (state, _) = home()
        let tab = state.openIncognitoTab(url: url("https://a.example"), activate: false, now: t0)
        let archived = state.runArchive(now: t0 + 100 * hour)
        #expect(!archived.contains { $0.url == tab.url })
        #expect(state.tab(tab.id) != nil)
    }

    /// An archived tab whose Space is gone restores into the active Space; from Incognito, the one it
    /// goes back to.
    @Test func archivedTabsRestoreOutsideIncognito() throws {
        var (state, _) = home()
        let work = state.addSpace(name: "Work", now: t0)
        let workTab = state.openTab(url: url("https://work.example"), inSpace: work.id, activate: false, now: t0)
        state.deleteSpace(work.id, now: t0 + hour)
        let entry = try #require(state.archived.first { $0.url == workTab.url })
        state.openIncognitoTab(url: url("https://a.example"), now: t0 + 2 * hour)
        let result = state.restore(archivedID: entry.id, now: t0 + 3 * hour)
        let restored = try #require(result)
        #expect(!restored.isIncognito && restored.spaceID == Space.defaultID)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == restored.id)
    }

    @Test func linksFromOtherAppsNeverOpenInIncognito() {
        var (state, _) = home()
        let work = state.addSpace(name: "Work", now: t0)
        state.switchToSpace(work.id, now: t0)
        state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        #expect(state.destinationForLink(requestedSpace: nil, focusSpace: nil) == (work.id, .lastUsed))
        #expect(state.destinationForLink(requestedSpace: Space.incognitoID, focusSpace: Space.incognitoID)
            == (work.id, .lastUsed))
        let summary = SpacesSummary(state)
        #expect(summary.spaces.map(\.id) == [Space.defaultID, work.id])
        #expect(summary.activeSpaceID == work.id)
    }

    @Test func persistedLeavesIncognitoOut() {
        var (state, homeTab) = home()
        state.openIncognitoTab(url: url("https://a.example"), title: "Secret", now: t0 + hour)
        state.openIncognitoTab(url: url("https://b.example"), activate: false, now: t0 + 2 * hour)
        let saved = state.persisted
        #expect(saved.tabs.map(\.id) == [homeTab.id])
        #expect(saved.activeSpaceID == Space.defaultID && saved.activeTabID == homeTab.id)
        #expect(saved.spaceBeforeIncognito == nil)
        #expect(!saved.isIncognitoOpen)
        // Without Incognito, unchanged.
        let (plain, _) = home()
        #expect(plain.persisted == plain)
    }

    @Test func encodingNeverWritesIncognito() throws {
        var (state, homeTab) = home()
        let tab = state.openIncognitoTab(url: url("https://secret.example/path"), title: "Secret page", now: t0 + hour)
        let data = try CoreJSON.encoder().encode(state)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("secret.example"))
        #expect(!json.contains("Secret page"))
        #expect(!json.contains(tab.id.uuidString))
        #expect(!json.contains(Space.incognitoID.uuidString))
        let decoded = try CoreJSON.decoder().decode(BrowserState.self, from: data)
        #expect(decoded.tabs.map(\.id) == [homeTab.id])
        #expect(decoded.activeSpaceID == Space.defaultID && decoded.activeTabID == homeTab.id)
    }

    @Test func aFileWithIncognitoInItLoadsWithout() throws {
        let homeTab = UUID(), privateTab = UUID()
        let json = """
        {"schemaVersion":4,"spaces":[{"id":"\(Space.defaultID)","name":"Home"},{"id":"\(Space.incognitoID)","name":"Incognito"}],
         "tabs":[{"id":"\(homeTab)","spaceID":"\(Space.defaultID)","url":"https://a.com","title":"","kind":"today","createdAt":0,"lastViewedAt":0},
                 {"id":"\(privateTab)","spaceID":"\(Space.incognitoID)","url":"https://b.com","title":"","kind":"today","createdAt":0,"lastViewedAt":1}],
         "archived":[],"activeSpaceID":"\(Space.incognitoID)","activeTabID":"\(privateTab)"}
        """
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.tabs.map(\.id) == [homeTab])
        #expect(state.spaces.map(\.id) == [Space.defaultID])
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == homeTab)
    }

    @Test func aSavedSpaceCantUseTheIncognitoProfile() {
        let work = Space(name: "Work", profileID: Profile.incognitoID)
        let state = BrowserState(spaces: [work], profiles: [.default, .incognito])
        #expect(state.profile(Profile.incognitoID) == nil)
        #expect(state.profile(forSpace: work.id).id == Profile.defaultID)
    }

    @Test func normalizeKeepsIncognitoTabsWhereTheyAre() {
        var (state, _) = home()
        let tab = state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        state.normalize()
        #expect(state.tab(tab.id)?.isIncognito == true)
        #expect(state.activeSpaceID == Space.incognitoID && state.activeTabID == tab.id)
        // Space edits normalize too.
        state.updateSpace(Space.defaultID) { $0.name = "House" }
        #expect(state.activeSpaceID == Space.incognitoID && state.tab(tab.id)?.isIncognito == true)
    }

    @Test func editingAndArchivingIncognitoDoNothing() {
        var (state, _) = home()
        state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        let archived = state.archiveSpace(Space.incognitoID, now: t0 + 2 * hour)
        let deleted = state.deleteSpace(Space.incognitoID, now: t0 + 2 * hour)
        let changedProfile = state.updateSpace(Space.incognitoID) { $0.name = "Public" }
        #expect(!archived && !deleted && !changedProfile)
        #expect(state.space(Space.incognitoID)?.name == "Incognito")
        #expect(state.isIncognitoOpen && state.activeSpaceID == Space.incognitoID)
    }

    @Test func archiveIdleTabsSwitchIgnoresIncognito() {
        var (state, _) = home()
        state.stopArchivingIdleTabs()
        state.openIncognitoTab(url: url("https://a.example"), now: t0)
        #expect(!state.archivesIdleTabs)
        state.resumeArchivingIdleTabs()
        #expect(state.archivesIdleTabs)
        #expect(state.space(Space.incognitoID)?.archivePolicy == .off)
    }

    @Test func switchingAwayAndBackKeepsIncognito() {
        var (state, homeTab) = home()
        let tab = state.openIncognitoTab(url: url("https://a.example"), now: t0 + hour)
        state.switchToSpace(Space.defaultID, now: t0 + 2 * hour)
        #expect(state.activeTabID == homeTab.id && state.isIncognitoOpen)
        state.switchToSpace(Space.incognitoID, now: t0 + 3 * hour)
        #expect(state.activeSpaceID == Space.incognitoID && state.activeTabID == tab.id)
        #expect(state.spaceBeforeIncognito == Space.defaultID)
        state.activate(tabID: homeTab.id, now: t0 + 4 * hour)
        state.activate(tabID: tab.id, now: t0 + 5 * hour)
        #expect(state.activeSpaceID == Space.incognitoID)
    }
}
