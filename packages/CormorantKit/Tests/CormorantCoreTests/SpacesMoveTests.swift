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
