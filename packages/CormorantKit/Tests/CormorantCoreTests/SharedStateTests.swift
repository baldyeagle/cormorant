import Foundation
import Testing
@testable import CormorantCore

@Suite struct SharedStateTests {
    private func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

    @Test func sharedLeavesOutIncognitoAndBlankTabs() {
        var state = BrowserState()
        let kept = state.openTab(url: url("a"))
        _ = state.openTab(url: nil)
        state.openIncognitoTab(url: url("secret"))
        #expect(state.shared.tabs.map(\.id) == [kept.id])
        #expect(!state.shared.spaces.contains { $0.isIncognito })
    }

    @Test func settingSharedKeepsWhatIsThisDevicesOwn() {
        var state = BrowserState()
        let old = state.openTab(url: url("old"))
        let blank = state.openTab(url: nil)
        let secret = state.openIncognitoTab(url: url("secret"))
        #expect(state.activeTabID == secret.id)

        let incoming = Tab(url: url("new"))
        var shared = state.shared
        shared.tabs = [incoming]
        state.setShared(shared)

        #expect(Set(state.tabs.map(\.id)) == [incoming.id, blank.id, secret.id])
        #expect(state.tab(old.id) == nil)
        #expect(state.activeSpaceID == Space.incognitoID)
        #expect(state.activeTabID == secret.id)
        #expect(state.spaceOutsideIncognito == Space.defaultID)
    }

    @Test func anIncomingIncognitoOrBlankTabIsNotTaken() {
        var state = BrowserState()
        var shared = state.shared
        shared.tabs = [Tab(spaceID: Space.incognitoID, url: url("x")), Tab(url: nil)]
        state.setShared(shared)
        #expect(state.tabs.isEmpty)
    }

    @Test func whenTheActiveTabGoesTheSpacesMostRecentTakesOver() {
        var state = BrowserState()
        let first = state.openTab(url: url("a"), now: Date(timeIntervalSinceReferenceDate: 10))
        let second = state.openTab(url: url("b"), now: Date(timeIntervalSinceReferenceDate: 20))
        #expect(state.activeTabID == second.id)
        var shared = state.shared
        shared.tabs.removeAll { $0.id == second.id }
        state.setShared(shared)
        #expect(state.activeTabID == first.id)
    }

    @Test func aProfileThatIsGoneIsErasedHere() {
        var state = BrowserState()
        let profile = state.addProfile(name: "Work")
        let space = state.addSpace(name: "Work", profileID: profile.id)
        var shared = state.shared
        shared.profiles.removeAll { $0.id == profile.id }
        state.setShared(shared)
        #expect(state.profilesToErase == [profile.id])
        #expect(state.space(space.id)?.profileID == Profile.defaultID)
    }

    @Test func aSpaceThatIsGoneMovesItsLocalTabsHomeAndLeavesIt() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.switchToSpace(work.id)
        let blank = state.openTab(url: nil)
        var shared = state.shared
        shared.spaces.removeAll { $0.id == work.id }
        state.setShared(shared)
        #expect(state.activeSpaceID == Space.defaultID)
        #expect(state.tab(blank.id)?.spaceID == Space.defaultID)
    }
}
