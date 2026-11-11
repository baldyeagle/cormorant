import Foundation
import Testing
@testable import CormorantCore

@Suite struct SpacesMoveTests {
    @Test func tabLooksUpOpenTabsOnly() {
        var state = BrowserState()
        let tab = state.openTab(url: url("https://a.com"), now: t0)
        #expect(state.tab(tab.id)?.url == url("https://a.com"))
        state.archive(tabID: tab.id, now: t0)
        #expect(state.tab(tab.id) == nil)
    }

    @Test func moveChangesProfileMatchesWhatMoveTabReports() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        let projects = state.addSpace(name: "Projects")
        let tab = state.openTab(url: url("https://a.com"), now: t0)

        #expect(state.moveChangesProfile(tab.id, toSpace: work.id))
        #expect(!state.moveChangesProfile(tab.id, toSpace: projects.id))
        #expect(!state.moveChangesProfile(tab.id, toSpace: Space.defaultID))  // where it is
        #expect(!state.moveChangesProfile(tab.id, toSpace: UUID()))
        #expect(!state.moveChangesProfile(UUID(), toSpace: work.id))

        let moved = state.moveTab(tab.id, toSpace: work.id, now: t0)
        #expect(moved == true)
        // From Work, back to either default-profile Space reloads; Work itself doesn't.
        #expect(state.moveChangesProfile(tab.id, toSpace: Space.defaultID))
        #expect(state.moveChangesProfile(tab.id, toSpace: projects.id))
        #expect(!state.moveChangesProfile(tab.id, toSpace: work.id))
    }

    @Test func movingTheActiveTabBackMakesItActiveAgain() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        let older = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)
        #expect(state.activeTabID == reading.id)

        state.moveTab(reading.id, toSpace: work.id, now: t0 + 2 * hour)
        #expect(state.activeTabID == older.id)

        let back = state.moveTabBack(reading.id, toSpace: Space.defaultID, wasActive: true, now: t0 + 3 * hour)
        #expect(back == true)
        #expect(state.tab(reading.id)?.spaceID == Space.defaultID)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)
        // The tab it gave way to counts as viewed when it's left, as any tab switch does.
        #expect(state.tab(older.id)?.lastViewedAt == t0 + 3 * hour)
    }

    @Test func movingABackgroundTabBackLeavesTheActiveTabAlone() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let background = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)

        state.moveTab(background.id, toSpace: projects.id, now: t0 + 2 * hour)
        let back = state.moveTabBack(background.id, toSpace: Space.defaultID, wasActive: false, now: t0 + 3 * hour)
        #expect(back == false)
        #expect(state.tab(background.id)?.spaceID == Space.defaultID)
        #expect(state.activeTabID == reading.id)
    }

    @Test func movingABackgroundTabBackRestoresItsPlace() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let old = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)
        state.activate(tabID: reading.id, now: t0 + hour)

        state.moveTab(old.id, toSpace: projects.id, now: t0 + 2 * hour)
        state.moveTabBack(old.id, toSpace: Space.defaultID, wasActive: false, lastViewedAt: t0, now: t0 + 3 * hour)
        #expect(state.tab(old.id)?.lastViewedAt == t0)
        #expect(state.activeSpaceTabs.map(\.id) == [reading.id, old.id])
        #expect(state.activeTabID == reading.id)
    }

    @Test func movingBackAfterSwitchingSpacesDoesNotSwitchBack() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let reading = state.openTab(url: url("https://b.com"), now: t0)
        state.moveTab(reading.id, toSpace: projects.id, now: t0 + hour)
        state.switchToSpace(projects.id, now: t0 + 2 * hour)
        #expect(state.activeTabID == reading.id)

        state.moveTabBack(reading.id, toSpace: Space.defaultID, wasActive: true, now: t0 + 3 * hour)
        #expect(state.activeSpaceID == projects.id && state.activeTabID == nil)
        #expect(state.tab(reading.id)?.spaceID == Space.defaultID)
    }

    @Test func movingAndFollowingGoesToTheTabInItsNewSpace() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        let older = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)
        let waiting = state.openTab(url: url("https://c.com"), inSpace: work.id, activate: false, now: t0)

        let moved = state.moveTabAndFollow(reading.id, toSpace: work.id, now: t0 + 2 * hour)
        #expect(moved == true)
        #expect(state.activeSpaceID == work.id && state.activeTabID == reading.id)
        #expect(state.activeSpaceTabs.map(\.id) == [reading.id, waiting.id])
        // Home keeps the tab it gave way to, for going back.
        state.switchToSpace(Space.defaultID, now: t0 + 3 * hour)
        #expect(state.activeTabID == older.id)

        #expect(state.moveTabAndFollow(older.id, toSpace: Space.defaultID, now: t0 + 4 * hour) == nil)
        #expect(state.activeSpaceID == Space.defaultID)
    }

    @Test func movingABackgroundTabAndFollowingMakesItActive() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let background = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)

        state.moveTabAndFollow(background.id, toSpace: projects.id, now: t0 + 2 * hour)
        #expect(state.activeSpaceID == projects.id && state.activeTabID == background.id)
        state.switchToSpace(Space.defaultID, now: t0 + 3 * hour)
        #expect(state.activeTabID == reading.id)
    }

    @Test func undoingAFollowedMoveGoesBackWithTheTab() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let older = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)
        let waiting = state.openTab(url: url("https://c.com"), inSpace: projects.id, activate: false, now: t0)

        state.moveTabAndFollow(reading.id, toSpace: projects.id, now: t0 + 2 * hour)
        let back = state.moveTabBack(reading.id, toSpace: Space.defaultID, wasActive: true, lastViewedAt: t0 + hour,
                                     returningTo: Space.defaultID, now: t0 + 3 * hour)
        #expect(back == false)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)
        #expect(state.activeSpaceTabs.map(\.id) == [reading.id, older.id])
        #expect(state.tab(waiting.id)?.spaceID == projects.id)
    }

    @Test func undoingAFollowedMoveOfABackgroundTabRestoresTheActiveTab() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let old = state.openTab(url: url("https://a.com"), now: t0)
        let reading = state.openTab(url: url("https://b.com"), now: t0 + hour)

        state.moveTabAndFollow(old.id, toSpace: projects.id, now: t0 + 2 * hour)
        state.moveTabBack(old.id, toSpace: Space.defaultID, wasActive: false, lastViewedAt: t0,
                          returningTo: Space.defaultID, now: t0 + 3 * hour)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)
        #expect(state.tab(old.id)?.lastViewedAt == t0)
        #expect(state.activeSpaceTabs.map(\.id) == [reading.id, old.id])
    }

    @Test func undoingAFollowedMoveFromElsewhereStaysThere() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let trip = state.addSpace(name: "Trip")
        let reading = state.openTab(url: url("https://b.com"), now: t0)

        // Back in Home first: the tab comes back to it, active again.
        state.moveTabAndFollow(reading.id, toSpace: projects.id, now: t0 + hour)
        state.switchToSpace(Space.defaultID, now: t0 + 2 * hour)
        state.moveTabBack(reading.id, toSpace: Space.defaultID, wasActive: true, lastViewedAt: t0,
                          returningTo: Space.defaultID, now: t0 + 3 * hour)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)

        // In a third Space: it stays there.
        state.moveTabAndFollow(reading.id, toSpace: projects.id, now: t0 + 4 * hour)
        state.switchToSpace(trip.id, now: t0 + 5 * hour)
        state.moveTabBack(reading.id, toSpace: Space.defaultID, wasActive: true, lastViewedAt: t0 + 3 * hour,
                          returningTo: Space.defaultID, now: t0 + 6 * hour)
        #expect(state.activeSpaceID == trip.id)
        #expect(state.tab(reading.id)?.spaceID == Space.defaultID)
    }

    @Test func undoingAFollowedMoveFromAnotherSpaceGoesBackToTheSpaceYouWereIn() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let projects = state.addSpace(name: "Projects")
        let reading = state.openTab(url: url("https://a.com"), now: t0)
        let link = state.openTab(url: url("https://b.com"), inSpace: work.id, activate: false, now: t0)

        // From Home, a Work tab goes to Projects; Undo puts it back in Work and you back in Home.
        state.moveTabAndFollow(link.id, toSpace: projects.id, now: t0 + hour)
        state.moveTabBack(link.id, toSpace: work.id, wasActive: false, lastViewedAt: t0,
                          returningTo: Space.defaultID, now: t0 + 2 * hour)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)
        #expect(state.tab(link.id)?.spaceID == work.id && state.tab(link.id)?.lastViewedAt == t0)

        // Into Home, the Space you're in: Undo leaves you there, with your tab.
        state.moveTabAndFollow(link.id, toSpace: Space.defaultID, now: t0 + 3 * hour)
        #expect(state.activeTabID == link.id)
        state.moveTabBack(link.id, toSpace: work.id, wasActive: false, lastViewedAt: t0,
                          returningTo: Space.defaultID, now: t0 + 4 * hour)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)
        #expect(state.tab(link.id)?.spaceID == work.id)
    }

    @Test func undoingAFollowedMoveAcrossProfilesReportsTheReload() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        let reading = state.openTab(url: url("https://a.com"), now: t0)

        #expect(state.moveTabAndFollow(reading.id, toSpace: work.id, now: t0 + hour) == true)
        let back = state.moveTabBack(reading.id, toSpace: Space.defaultID, wasActive: true, lastViewedAt: t0,
                                     returningTo: Space.defaultID, now: t0 + 2 * hour)
        #expect(back == true)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == reading.id)
    }

    @Test func movingBackIsANoOpOnceTheSpaceOrTabIsGone() {
        var state = BrowserState()
        let projects = state.addSpace(name: "Projects")
        let trip = state.addSpace(name: "Trip")
        let tab = state.openTab(url: url("https://a.com"), inSpace: trip.id, activate: false, now: t0)
        state.moveTab(tab.id, toSpace: projects.id, now: t0)
        state.archiveSpace(trip.id, now: t0 + hour)

        let toArchived = state.moveTabBack(tab.id, toSpace: trip.id, wasActive: false, now: t0 + 2 * hour)
        #expect(toArchived == nil)
        #expect(state.tab(tab.id)?.spaceID == projects.id)

        state.archive(tabID: tab.id, now: t0 + 2 * hour)
        let closed = state.moveTabBack(tab.id, toSpace: Space.defaultID, wasActive: true, now: t0 + 3 * hour)
        #expect(closed == nil)
    }
}
