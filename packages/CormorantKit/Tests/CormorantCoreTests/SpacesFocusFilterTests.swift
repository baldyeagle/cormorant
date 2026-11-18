import Foundation
import Testing
@testable import CormorantCore

/// Edit Space's Focus group: on for the Space the Focus filter names, how to set one up for the others,
/// and none with only Home or for an archived or unknown Space.
@Suite struct SpacesFocusFilterTests {
    @Test func onForTheFiltersSpaceOffForTheOthers() {
        var state = BrowserState.empty
        let work = state.addSpace(name: "Work", now: t0)
        let projects = state.addSpace(name: "Projects", now: t0)

        let on = state.focusFilterGroup(editing: work.id, named: "Work", focusSpace: work.id)
        #expect(on == FocusFilterGroup(isOn: true, status: "On now: links from other apps open in Work",
                                       footer: "When the Focus ends, links open in the last Space you used."))

        let off = state.focusFilterGroup(editing: projects.id, named: "Projects", focusSpace: work.id)
        #expect(off == FocusFilterGroup(isOn: false, status: "Off",
                                        footer: "To open links from other apps in Projects during a Focus, go to Settings › Focus, choose a Focus, then Add Filter › Cormorant › Projects."))
        #expect(state.focusFilterGroup(editing: projects.id, named: "Projects", focusSpace: nil)?.isOn == false)
    }

    /// The name being typed says where links will open; the filter's Space list in iOS Settings still
    /// has the saved name until Save.
    @Test func renamingUsesTheFieldsNameButSettingsShowsTheSavedOne() {
        var state = BrowserState.empty
        let projects = state.addSpace(name: "Projects", now: t0)
        let group = state.focusFilterGroup(editing: projects.id, named: "Builds", focusSpace: nil)
        #expect(group?.footer == "To open links from other apps in Builds during a Focus, go to Settings › Focus, choose a Focus, then Add Filter › Cormorant › Projects.")
        #expect(state.focusFilterGroup(editing: projects.id, named: "Builds", focusSpace: projects.id)?.status
            == "On now: links from other apps open in Builds")
    }

    @Test func noneWithOnlyHomeOrForASpaceOutOfReach() {
        var state = BrowserState.empty
        #expect(state.focusFilterGroup(editing: Space.defaultID, named: "Home", focusSpace: Space.defaultID) == nil)

        let work = state.addSpace(name: "Work", now: t0)
        let trip = state.addSpace(name: "Trip", now: t0)
        #expect(state.focusFilterGroup(editing: Space.defaultID, named: "Home", focusSpace: nil) != nil)
        #expect(state.focusFilterGroup(editing: UUID(), named: "Gone", focusSpace: nil) == nil)
        let archived = state.archiveSpace(trip.id, now: t0)
        #expect(archived)
        #expect(state.focusFilterGroup(editing: trip.id, named: "Trip", focusSpace: trip.id) == nil)
        #expect(state.focusFilterGroup(editing: work.id, named: "Work", focusSpace: work.id)?.isOn == true)
    }
}
