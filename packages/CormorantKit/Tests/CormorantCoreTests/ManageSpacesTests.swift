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
}
