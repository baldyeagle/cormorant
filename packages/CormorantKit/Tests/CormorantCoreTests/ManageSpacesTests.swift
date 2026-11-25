import Foundation
import Testing
@testable import CormorantCore

@Suite struct ManageSpacesTests {
    @Test func suggestedLookSkipsIconsAndColorsInUse() {
        var state = BrowserState()
        #expect(state.suggestedNewSpaceLook == (.briefcase, .indigo))

        let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo)
        #expect(state.suggestedNewSpaceLook == (.hammer, .orange))

        // Archived Spaces still hold their look: they come back.
        state.archiveSpace(work.id, now: t0)
        #expect(state.suggestedNewSpaceLook == (.hammer, .orange))

        // Out of order: the first free one, not the one after the last used.
        state.addSpace(name: "Trip", icon: .airplane, color: .green)
        #expect(state.suggestedNewSpaceLook == (.hammer, .orange))
    }

    @Test func suggestedLookFallsBackToTheFirstOnceAllAreTaken() {
        var state = BrowserState()
        for (icon, color) in zip(SpaceIcon.allCases, Swatch.allCases + Array(repeating: .gray, count: 12)) {
            state.addSpace(name: icon.rawValue, icon: icon, color: color)
        }
        #expect(state.suggestedNewSpaceLook == (SpaceIcon.allCases[0], Swatch.allCases[0]))
    }

    @Test func tabsDueFollowsThePolicyGivenOrTheSpacesOwn() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.updateSpace(work.id) { $0.archivePolicy = .off }
        let hour: TimeInterval = 60 * 60
        let idle13h = Tab(spaceID: work.id, url: url("https://a.com"), createdAt: t0 - 13 * hour)
        let idle2h = Tab(spaceID: work.id, url: url("https://b.com"), createdAt: t0 - 2 * hour)
        let home = Tab(url: url("https://c.com"), createdAt: t0 - 30 * hour)
        state = BrowserState(spaces: state.spaces, tabs: [idle13h, idle2h, home])

        // Off: nothing. Twelve hours: only the tab idle longer, and only in this Space.
        #expect(state.tabsDue(inSpace: work.id, now: t0).isEmpty)
        #expect(state.tabsDue(inSpace: work.id, policy: .twelveHours, now: t0).map(\.id) == [idle13h.id])
        #expect(state.tabsDue(inSpace: work.id, policy: .oneDay, now: t0).isEmpty)
        #expect(state.tabsDue(inSpace: Space.defaultID, now: t0).map(\.id) == [home.id])
        #expect(state.tabsDue(inSpace: UUID(), policy: .twelveHours, now: t0).isEmpty)
    }

    @Test func tabsDueSparesTheActiveTabAndArchivedSpaces() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let old = Tab(spaceID: work.id, url: url("https://a.com"), createdAt: t0 - 48 * 60 * 60)
        state = BrowserState(spaces: state.spaces, tabs: [old], activeSpaceID: work.id, activeTabID: old.id)
        #expect(state.tabsDue(inSpace: work.id, policy: .twelveHours, now: t0).isEmpty)

        state.switchToSpace(Space.defaultID, now: t0 - 48 * 60 * 60)
        #expect(state.tabsDue(inSpace: work.id, policy: .twelveHours, now: t0).map(\.id) == [old.id])
        state.archiveSpace(work.id, now: t0)
        #expect(state.tabsDue(inSpace: work.id, policy: .twelveHours, now: t0).isEmpty)
    }

    @Test func closedTabsReopeningHereLeaveOutOtherSpaces() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let trip = state.addSpace(name: "Trip")
        let gone = state.addSpace(name: "Gone")
        let home = state.openTab(url: url("https://home.com"))
        state.archive(tabID: home.id)
        for (space, host) in [(work, "work.com"), (trip, "trip.com"), (gone, "gone.com")] {
            state.switchToSpace(space.id)
            let tab = state.openTab(url: url("https://\(host)"))
            state.archive(tabID: tab.id)
        }
        state.switchToSpace(Space.defaultID)
        state.archiveSpace(trip.id)
        state.deleteSpace(gone.id)
        let hosts = Set(state.archived(reopeningIn: Space.defaultID).map { $0.url.host() ?? "" })
        #expect(hosts == ["home.com", "trip.com", "gone.com"])
    }

    @Test func archiveConfirmationSaysWhatIsKeptAndHowItComesBack() {
        let back = "leaves the Spaces you switch between until you restore it from Archived in Spaces."
        #expect(Space.archiveConfirmation(name: "Work", tabCount: 0) == "It has no open tabs. Work \(back)")
        #expect(Space.archiveConfirmation(name: "Work", tabCount: 1)
            == "Its tab is kept, and doesn't archive while the Space is away. Work \(back)")
        #expect(Space.archiveConfirmation(name: "Trip", tabCount: 3)
            == "Its 3 tabs are kept, and don't archive while the Space is away. Trip \(back)")
    }

    @Test func archiveConfirmationNamesWhereItsRestoredFrom() {
        #expect(Space.archiveConfirmation(name: "Work", tabCount: 0, restoredFrom: "the Library")
            == "It has no open tabs. Work leaves the Spaces you switch between until you restore it from the Library.")
    }

    @Test func aSpacesNameCarriesItsProfileWhereThatIsntTheDefault() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi", color: .gold)
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        #expect(state.nameWithProfile(of: work) == "Work · Vialumi")
        #expect(state.nameWithProfile(of: state.activeSpace) == "Home")
        #expect(state.nameWithProfile(of: .incognito) == "Incognito")
    }

    @Test func switchingProfilesWarnsOnlyWhenTabsReload() throws {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi", color: .gold)
        let work = state.addSpace(name: "Work")
        #expect(state.profileSwitchWarning(spaceID: work.id, to: vialumi.id) == nil)

        _ = state.openTab(url: url("https://a.com"), inSpace: work.id)
        #expect(state.profileSwitchWarning(spaceID: work.id, to: vialumi.id)
            == "Work's tab reloads with Vialumi's logins and cookies. Nothing in Default is deleted.")
        _ = state.openTab(url: url("https://b.com"), inSpace: work.id)
        #expect(state.profileSwitchWarning(spaceID: work.id, to: vialumi.id)
            == "Work's 2 tabs reload with Vialumi's logins and cookies. Nothing in Default is deleted.")
        #expect(state.profileSwitchWarning(spaceID: work.id, to: Profile.defaultID) == nil)
        #expect(state.profileSwitchWarning(spaceID: work.id, to: UUID()) == nil)
    }

    @Test func aShorterArchiveTimeSaysWhichTabsItWillTake() {
        var state = BrowserState()
        let now = t0 + 100 * hour
        _ = state.openTab(url: url("https://day-old.com"), now: now - 30 * hour)
        _ = state.openTab(url: url("https://fresh.com"), now: now - hour)
        _ = state.openTab(url: url("https://active.com"), now: now)
        #expect(state.idleTabsNote(inSpace: Space.defaultID, comparedWith: .oneDay, now: now) == nil)

        state.updateSpace(Space.defaultID) { $0.archivePolicy = .twelveHours }
        // The day-old tab went at 24 hours too; nothing new to say.
        #expect(state.idleTabsNote(inSpace: Space.defaultID, comparedWith: .oneDay, now: now) == nil)
        #expect(state.idleTabsNote(inSpace: Space.defaultID, comparedWith: .sevenDays, now: now)
            == "1 tab here has been idle longer than that, and will move to the tab archive the next time you come back to Cormorant.")

        state.updateSpace(Space.defaultID) { $0.archivePolicy = ArchivePolicy(interval: 30 * 60) }
        #expect(state.idleTabsNote(inSpace: Space.defaultID, comparedWith: .sevenDays, now: now)?.hasPrefix("2 tabs here have") == true)
    }

    @Test func restoringSaysWhatComesBack() {
        #expect(Space.restoreSubtitle(tabCount: 0) == "Restore")
        #expect(Space.restoreSubtitle(tabCount: 1) == "Restore with its tab")
        #expect(Space.restoreSubtitle(tabCount: 4) == "Restore with its 4 tabs")
    }

    @Test func deleteConfirmationSaysWhereTheTabsGo() {
        #expect(Space.deleteConfirmation(tabCount: 0) == "It has no open tabs. The Space and its settings are gone.")
        #expect(Space.deleteConfirmation(tabCount: 1)
            == "Its tab goes to the tab archive, where you can search for it and reopen it. The Space and its settings are gone.")
        #expect(Space.deleteConfirmation(tabCount: 2)
            == "Its 2 tabs go to the tab archive, where you can search for them and reopen them. The Space and its settings are gone.")
    }
}
