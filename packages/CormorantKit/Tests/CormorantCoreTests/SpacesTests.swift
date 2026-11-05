import Foundation
import Testing
@testable import CormorantCore

@Suite struct SpacesTests {
    @Test func newStateHasHomeOnTheDefaultProfile() {
        let state = BrowserState()
        #expect(state.spaces.map(\.id) == [Space.defaultID])
        #expect(state.profiles.map(\.id) == [Profile.defaultID])
        #expect(state.profiles.first?.name == "Default")
        #expect(state.activeSpace.profileID == Profile.defaultID)
        #expect(state.activeSpace.archivePolicy == .oneDay)
    }

    @Test func normalizeRestoresInvariants() {
        let ghostProfile = UUID()
        let work = Space(name: "Work", profileID: ghostProfile)
        let orphan = Tab(spaceID: UUID(), url: url("https://a.com"))
        var state = BrowserState(spaces: [work], profiles: [], tabs: [orphan],
                                 activeSpaceID: UUID(), activeTabID: UUID())
        #expect(state.spaces.map(\.id) == [Space.defaultID, work.id])
        #expect(state.profiles.map(\.id) == [Profile.defaultID])
        #expect(state.space(work.id)?.profileID == Profile.defaultID)
        #expect(state.tabs.first?.spaceID == Space.defaultID)
        #expect(state.activeSpaceID == Space.defaultID)
        // The dangling active tab is cleared, then switching to Home picks its most recent tab.
        #expect(state.activeTabID == orphan.id)

        state.spaces[0].archivedAt = t0
        state.normalize()
        #expect(!state.spaces[0].isArchived)
    }

    @Test func decodesPreProfileFilesOntoTheDefaultProfile() throws {
        let workID = UUID()
        let json = """
        {"schemaVersion":1,"spaces":[{"id":"\(Space.defaultID)","name":"Home"},{"id":"\(workID)","name":"Work"}],
         "tabs":[],"archived":[],"activeSpaceID":"\(workID)"}
        """
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.profiles.map(\.id) == [Profile.defaultID])
        let work = try #require(state.space(workID))
        #expect(work.profileID == Profile.defaultID && work.icon == .house && work.color == .teal)
        #expect(work.archivePolicy == .oneDay && !work.isArchived)
        #expect(state.activeSpaceID == workID)
    }

    @Test func unknownIconAndColorDecodeAsDefaults() throws {
        let json = "{\"id\":\"\(UUID())\",\"name\":\"X\",\"icon\":\"sparkles.future\",\"color\":\"ultraviolet\"}"
        let space = try CoreJSON.decoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.icon == .house && space.color == .teal)
    }

    @Test func spacesAndProfilesRoundTrip() throws {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi", color: .indigo, now: t0)
        let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo, profileID: vialumi.id, now: t0)
        state.updateSpace(work.id) { $0.archivePolicy = .off }
        let trip = state.addSpace(name: "Japan trip", icon: .airplane, color: .green, now: t0)
        state.archiveSpace(trip.id, now: t0 + hour)
        _ = state.openTab(url: url("https://a.com"), now: t0)

        let data = try CoreJSON.encoder().encode(state)
        let loaded = try CoreJSON.decoder().decode(BrowserState.self, from: data)
        #expect(loaded == state)
        #expect(loaded.space(work.id)?.archivePolicy == .off)
    }

    @Test func switchToSpaceActivatesItsMostRecentTab() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let home = state.openTab(url: url("https://home.com"), now: t0)
        state.tabs.append(Tab(spaceID: work.id, url: url("https://old.com"), createdAt: t0))
        let recent = Tab(spaceID: work.id, url: url("https://recent.com"), createdAt: t0 + hour)
        state.tabs.append(recent)

        state.switchToSpace(work.id)
        #expect(state.activeSpaceID == work.id && state.activeTabID == recent.id)
        #expect(state.activeSpaceTabs.map(\.id).first == recent.id)

        let empty = state.addSpace(name: "Empty")
        state.switchToSpace(empty.id)
        #expect(state.activeSpaceID == empty.id && state.activeTabID == nil)

        state.switchToSpace(Space.defaultID)
        #expect(state.activeTabID == home.id)

        state.switchToSpace(UUID())
        #expect(state.activeSpaceID == Space.defaultID)
    }

    @Test func addSpaceFallsBackToTheDefaultProfileAndAppends() {
        var state = BrowserState()
        let a = state.addSpace(name: "A", profileID: UUID())
        let b = state.addSpace(name: "B")
        #expect(a.profileID == Profile.defaultID)
        #expect(state.spaces.map(\.id) == [Space.defaultID, a.id, b.id])
        #expect(state.activeSpaceID == Space.defaultID)
    }

    @Test func archivingKeepsTabsAndLeavesSwitching() {
        var state = BrowserState()
        let trip = state.addSpace(name: "Japan trip")
        state.switchToSpace(trip.id)
        let tab = state.openTab(url: url("https://jr.com"), now: t0)
        let home = Tab(url: url("https://home.com"), createdAt: t0)
        state.tabs.append(home)

        let archived = state.archiveSpace(trip.id, now: t0 + hour)

        #expect(archived)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == home.id)
        #expect(state.tabs.contains { $0.id == tab.id })
        #expect(state.switchableSpaces.map(\.id) == [Space.defaultID])
        #expect(state.archivedSpaces.map(\.id) == [trip.id])

        // Archived Spaces can't be switched to, and their tabs don't auto-archive.
        state.switchToSpace(trip.id)
        #expect(state.activeSpaceID == Space.defaultID)
        let staleHome = Tab(url: url("https://stale.com"), createdAt: t0)
        state.tabs.append(staleHome)
        state.runArchive(now: t0 + 1_000 * hour)
        #expect(state.tabs.contains { $0.id == tab.id })
        #expect(!state.tabs.contains { $0.id == staleHome.id })

        let archivedAgain = state.archiveSpace(trip.id)

        #expect(!archivedAgain)
        state.restoreSpace(trip.id)
        #expect(state.switchableSpaces.map(\.id) == [Space.defaultID, trip.id])
    }

    @Test func homeCanBeRenamedButNotArchivedOrDeleted() {
        var state = BrowserState()
        state.updateSpace(Space.defaultID) { $0.name = "Personal" }
        #expect(state.activeSpace.name == "Personal")
        let archivedHome = state.archiveSpace(Space.defaultID)
        #expect(!archivedHome)
        let deletedHome = state.deleteSpace(Space.defaultID)
        #expect(!deletedHome)
        state.updateSpace(Space.defaultID) { $0.archivedAt = t0 }
        #expect(!state.activeSpace.isArchived)
    }

    @Test func updateSpaceCantArchiveOrRestore() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.switchToSpace(work.id)
        state.updateSpace(work.id) { $0.archivedAt = t0 }
        #expect(state.space(work.id)?.isArchived == false && state.activeSpaceID == work.id)
        state.archiveSpace(work.id, now: t0)
        state.updateSpace(work.id) { $0 = Space(id: work.id, name: "Stale copy") }
        #expect(state.space(work.id)?.isArchived == true && state.space(work.id)?.name == "Stale copy")
    }

    @Test func deleteSpaceSendsItsTabsToTheArchive() throws {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.switchToSpace(work.id)
        let page = state.openTab(url: url("https://work.com"), title: "Work", now: t0)
        _ = state.openTab(url: nil, now: t0)
        state.tabs.append(Tab(spaceID: work.id, url: url("https://pinned.com"), kind: .pinned, createdAt: t0))
        let home = Tab(url: url("https://home.com"), createdAt: t0)
        state.tabs.append(home)

        let deleted = state.deleteSpace(work.id, now: t0 + hour)

        #expect(deleted)
        #expect(state.space(work.id) == nil)
        #expect(state.tabs.map(\.id) == [home.id])
        #expect(Set(state.archived.map(\.url)) == [url("https://work.com"), url("https://pinned.com")])
        #expect(state.archived.allSatisfy { $0.spaceID == work.id && $0.archivedAt == t0 + hour })
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == home.id)

        // A deleted Space's tab restores into the active Space.
        let entry = try #require(state.archived.first { $0.id == page.id })
        let restoredTab = state.restore(archivedID: entry.id)
        let restored = try #require(restoredTab)
        #expect(restored.spaceID == Space.defaultID)
        let deletedAgain = state.deleteSpace(work.id)
        #expect(!deletedAgain)
    }

    @Test func moveTabReportsProfileChangesAndHandsOffTheActiveTab() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        let projects = state.addSpace(name: "Projects")
        let older = state.openTab(url: url("https://a.com"), now: t0)
        let moving = state.openTab(url: url("https://b.com"), now: t0 + hour)

        let toProjects = state.moveTab(moving.id, toSpace: projects.id)

        #expect(toProjects == false)
        #expect(state.tabs.first { $0.id == moving.id }?.spaceID == projects.id)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == older.id)

        let toWork = state.moveTab(moving.id, toSpace: work.id)

        #expect(toWork == true)
        #expect(state.activeTabID == older.id)  // a background tab moving leaves the active one alone
        let toSameSpace = state.moveTab(moving.id, toSpace: work.id)
        #expect(toSameSpace == nil)
        let toUnknownSpace = state.moveTab(moving.id, toSpace: UUID())
        #expect(toUnknownSpace == nil)
        let unknownTab = state.moveTab(UUID(), toSpace: projects.id)
        #expect(unknownTab == nil)

        let activeToProjects = state.moveTab(older.id, toSpace: projects.id)

        #expect(activeToProjects == false)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == nil)
    }

    @Test func deleteProfileMovesItsSpacesToTheDefault() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        let launch = state.addSpace(name: "Launch", profileID: vialumi.id)
        let home = state.addSpace(name: "Other")

        #expect(state.spaces(usingProfile: vialumi.id).map(\.id) == [work.id, launch.id])
        #expect(state.profile(forSpace: work.id).id == vialumi.id)
        let affected = state.deleteProfile(vialumi.id)
        #expect(affected == [work.id, launch.id])
        #expect(state.profile(vialumi.id) == nil)
        #expect(state.profile(forSpace: work.id).id == Profile.defaultID)
        #expect(state.profile(forSpace: home.id).id == Profile.defaultID)
        let deletedDefault = state.deleteProfile(Profile.defaultID)
        #expect(deletedDefault == nil)
        let deletedAgain = state.deleteProfile(vialumi.id)
        #expect(deletedAgain == nil)
    }

    @Test func profileMonogramAndRename() {
        var state = BrowserState()
        state.updateProfile(Profile.defaultID) { $0.name = "personal" }
        #expect(state.profile(Profile.defaultID)?.monogram == "P")
        #expect(Profile(name: "  ").monogram == "?")
    }

    @Test func runArchiveUsesEachSpacesPolicy() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.updateSpace(work.id) { $0.archivePolicy = .twelveHours }
        let homeTab = state.openTab(url: url("https://home.com"), activate: false, now: t0)
        let workTab = Tab(spaceID: work.id, url: url("https://work.com"), createdAt: t0)
        state.tabs.append(workTab)

        let archived = state.runArchive(now: t0 + 13 * hour)
        #expect(archived.map(\.id) == [workTab.id])
        #expect(state.tabs.map(\.id) == [homeTab.id])
    }

    @Test func restoringATabFromAnArchivedSpaceOpensItInTheActiveSpace() throws {
        var state = BrowserState()
        let trip = state.addSpace(name: "Japan trip")
        state.switchToSpace(trip.id)
        let closed = state.openTab(url: url("https://jr.com"), now: t0)
        state.archive(tabID: closed.id, now: t0)
        state.archiveSpace(trip.id, now: t0 + hour)

        let restored = state.restore(archivedID: closed.id)
        let tab = try #require(restored)
        #expect(tab.spaceID == Space.defaultID)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == tab.id)
    }

    @Test func activatingATabInAnArchivedSpaceRestoresTheSpace() {
        var state = BrowserState()
        let trip = state.addSpace(name: "Japan trip")
        let tab = Tab(spaceID: trip.id, url: url("https://jr.com"), createdAt: t0)
        state.tabs.append(tab)
        state.archiveSpace(trip.id, now: t0)

        state.activate(tabID: tab.id, now: t0 + hour)
        #expect(state.space(trip.id)?.isArchived == false)
        #expect(state.activeSpaceID == trip.id && state.activeTabID == tab.id)
        let restoredAgain = state.restoreSpace(trip.id)
        #expect(!restoredAgain)
    }

    @Test func moveTabRejectsArchivedSpacesAndCountsAsAView() {
        var state = BrowserState()
        let trip = state.addSpace(name: "Japan trip")
        let work = state.addSpace(name: "Work")
        state.updateSpace(work.id) { $0.archivePolicy = .twelveHours }
        state.archiveSpace(trip.id, now: t0)
        let tab = state.openTab(url: url("https://a.com"), activate: false, now: t0)

        let toArchived = state.moveTab(tab.id, toSpace: trip.id, now: t0 + 20 * hour)
        #expect(toArchived == nil)
        let toWork = state.moveTab(tab.id, toSpace: work.id, now: t0 + 20 * hour)
        #expect(toWork == false)
        #expect(state.tabs.first?.lastViewedAt == t0 + 20 * hour)
        state.runArchive(now: t0 + 21 * hour)
        #expect(state.tabs.map(\.id) == [tab.id])
    }

    @Test func updateSpaceReportsProfileChanges() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work")
        let renamed = state.updateSpace(work.id) { $0.name = "Work stuff" }
        #expect(!renamed)
        let reassigned = state.updateSpace(work.id) { $0.profileID = vialumi.id }
        #expect(reassigned)
        let toGhost = state.updateSpace(work.id) { $0.profileID = UUID() }
        #expect(toGhost)  // an unknown profile falls back to the default, which is a change
        #expect(state.profile(forSpace: work.id).id == Profile.defaultID)
    }

    @Test func decodingRepairsAnArchivedActiveSpace() throws {
        let tripID = UUID(), homeTab = UUID()
        let json = """
        {"schemaVersion":2,"spaces":[{"id":"\(Space.defaultID)","name":"Home"},
          {"id":"\(tripID)","name":"Trip","archivedAt":0}],
         "tabs":[{"id":"\(homeTab)","url":"https://a.com","spaceID":"\(Space.defaultID)"}],
         "activeSpaceID":"\(tripID)"}
        """
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == homeTab)
        #expect(state.space(tripID)?.isArchived == true)
    }

    @Test func archivePolicyDecodesOffAndSurvivesUnknownShapes() throws {
        func space(_ policy: String) throws -> Space {
            let json = "{\"id\":\"\(UUID())\",\"name\":\"X\",\"archivePolicy\":\(policy)}"
            return try CoreJSON.decoder().decode(Space.self, from: Data(json.utf8))
        }
        #expect(try space("{\"interval\":null}").archivePolicy == .off)
        #expect(try space("{\"interval\":43200}").archivePolicy == .twelveHours)
        // Shapes a newer build might write fall back to the default, not to off.
        #expect(try space("{}").archivePolicy == .oneDay)
        #expect(try space("{\"days\":7}").archivePolicy == .oneDay)
        #expect(try space("\"oneWeek\"").archivePolicy == .oneDay)
        let encoded = try CoreJSON.encoder().encode(ArchivePolicy.off)
        #expect(String(decoding: encoded, as: UTF8.self) == "{\"interval\":null}")
    }

    @Test func iconAndColorOfAnotherTypeDecodeAsDefaults() throws {
        let json = "{\"id\":\"\(UUID())\",\"name\":\"X\",\"icon\":{\"emoji\":\"x\"},\"color\":{\"rgb\":\"#f00\"}}"
        let space = try CoreJSON.decoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.icon == .house && space.color == .teal)
        let profileJSON = "{\"id\":\"\(UUID())\",\"name\":\"P\",\"color\":7}"
        #expect(try CoreJSON.decoder().decode(Profile.self, from: Data(profileJSON.utf8)).color == .teal)
    }

    @Test func restoringASpaceDoesNotLetItsTabsComeBackDue() {
        var state = BrowserState()
        let trip = state.addSpace(name: "Trip")
        state.switchToSpace(trip.id, now: t0)
        let a = state.openTab(url: url("https://a.com"), now: t0)
        let b = state.openTab(url: url("https://b.com"), now: t0 + 60)
        state.switchToSpace(Space.defaultID, now: t0 + hour)
        let archived = state.archiveSpace(trip.id, now: t0 + hour)
        #expect(archived)

        let restored = state.restoreSpace(trip.id, now: t0 + 7 * 24 * hour)
        #expect(restored)
        let order = state.tabs(inSpace: trip.id).map(\.id)
        #expect(order == [b.id, a.id])
        state.runArchive(now: t0 + 7 * 24 * hour + 2 * hour)
        #expect(Set(state.tabs(inSpace: trip.id).map(\.id)) == [a.id, b.id])
        // Idle time resumes from the restore.
        state.runArchive(now: t0 + 8 * 24 * hour)
        #expect(state.tabs(inSpace: trip.id).isEmpty)
    }

    @Test func activatingATabInAnArchivedSpaceKeepsItsSiblings() {
        var state = BrowserState()
        let trip = state.addSpace(name: "Trip")
        state.switchToSpace(trip.id, now: t0)
        let a = state.openTab(url: url("https://a.com"), now: t0)
        let b = state.openTab(url: url("https://b.com"), now: t0)
        state.switchToSpace(Space.defaultID, now: t0)
        state.archiveSpace(trip.id, now: t0)
        state.activate(tabID: a.id, now: t0 + 30 * 24 * hour)
        state.runArchive(now: t0 + 30 * 24 * hour + hour)
        #expect(Set(state.tabs(inSpace: trip.id).map(\.id)) == [a.id, b.id])
    }

    @Test func normalizeKeepsTheActiveTabInTheActiveSpace() throws {
        let workID = UUID(), tripID = UUID(), homeTab = UUID(), workTab = UUID(), tripTab = UUID()
        func decode(activeTab: UUID) throws -> BrowserState {
            let json = """
            {"spaces":[{"id":"\(Space.defaultID)","name":"Home"},{"id":"\(workID)","name":"Work"},
              {"id":"\(tripID)","name":"Trip","archivedAt":0}],
             "tabs":[{"id":"\(homeTab)","url":"https://a.com"},
               {"id":"\(workTab)","url":"https://b.com","spaceID":"\(workID)"},
               {"id":"\(tripTab)","url":"https://c.com","spaceID":"\(tripID)"}],
             "activeSpaceID":"\(Space.defaultID)","activeTabID":"\(activeTab)"}
            """
            return try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        }
        #expect(try decode(activeTab: workTab).activeTabID == homeTab)
        #expect(try decode(activeTab: tripTab).activeTabID == homeTab)
        #expect(try decode(activeTab: homeTab).activeTabID == homeTab)
    }

    @Test func normalizeDropsDuplicateSpacesAndProfiles() {
        let work = Space(name: "Work")
        let state = BrowserState(spaces: [.default, work, .default, work], profiles: [.default, .default])
        #expect(state.spaces.map(\.id) == [Space.defaultID, work.id])
        #expect(state.profiles.map(\.id) == [Profile.defaultID])
    }

    @Test func switchingSpacesCountsTheTabsLeftAndArrivedAtAsViewed() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let reading = state.openTab(url: url("https://a.com"), now: t0)
        _ = state.openTab(url: url("https://b.com"), activate: false, now: t0 + 60)
        state.switchToSpace(work.id, now: t0 + hour)
        #expect(state.tabs.first { $0.id == reading.id }?.lastViewedAt == t0 + hour)
        state.switchToSpace(Space.defaultID, now: t0 + 2 * hour)
        #expect(state.activeTabID == reading.id)
        #expect(state.tabs.first { $0.id == reading.id }?.lastViewedAt == t0 + 2 * hour)

        // Switching to the active Space changes nothing.
        let background = state.openTab(url: url("https://c.com"), activate: false, now: t0 + 3 * hour)
        state.switchToSpace(Space.defaultID, now: t0 + 4 * hour)
        #expect(state.activeTabID == reading.id)
        #expect(state.tabs.first { $0.id == background.id }?.lastViewedAt == t0 + 3 * hour)
        #expect(state.tabs.first { $0.id == reading.id }?.lastViewedAt == t0 + 2 * hour)
    }

    @Test func openTabInAnotherSpaceLeavesTheActiveTabAlone() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let trip = state.addSpace(name: "Trip")
        state.archiveSpace(trip.id)
        let home = state.openTab(url: url("https://a.com"))
        let popup = state.openTab(url: url("https://b.com"), inSpace: work.id)
        #expect(popup.spaceID == work.id)
        #expect(state.activeSpaceID == Space.defaultID && state.activeTabID == home.id)
        let toArchived = state.openTab(url: url("https://c.com"), inSpace: trip.id)
        let toGhost = state.openTab(url: url("https://d.com"), inSpace: UUID())
        #expect(toArchived.spaceID == Space.defaultID && toGhost.spaceID == Space.defaultID)
        #expect(state.activeTabID == toGhost.id)
    }

    @Test func movingATabIntoAnEmptyActiveSpaceActivatesIt() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.switchToSpace(work.id)
        let tab = state.openTab(url: url("https://a.com"))
        state.switchToSpace(Space.defaultID)
        #expect(state.activeTabID == nil)
        let moved = state.moveTab(tab.id, toSpace: Space.defaultID)
        #expect(moved == false)
        #expect(state.activeTabID == tab.id)
    }

    @Test func moveSpaceReorders() {
        var state = BrowserState()
        let a = state.addSpace(name: "A")
        let b = state.addSpace(name: "B")
        state.moveSpace(b.id, before: Space.defaultID)
        #expect(state.spaces.map(\.id) == [b.id, Space.defaultID, a.id])
        state.moveSpace(b.id, before: nil)
        #expect(state.spaces.map(\.id) == [Space.defaultID, a.id, b.id])
        state.moveSpace(Space.defaultID, before: b.id)
        #expect(state.spaces.map(\.id) == [a.id, Space.defaultID, b.id])
        state.moveSpace(a.id, before: a.id)
        state.moveSpace(UUID(), before: nil)
        #expect(state.spaces.map(\.id) == [a.id, Space.defaultID, b.id])
    }

    @Test func blankTabsAndArchiveEntriesCanBeRemoved() {
        var state = BrowserState()
        let page = state.openTab(url: url("https://a.com"))
        _ = state.openTab(url: nil)
        state.removeBlankTabs()
        #expect(state.tabs.map(\.id) == [page.id] && state.activeTabID == nil)
        state.archive(tabID: page.id)
        state.deleteArchived(page.id)
        #expect(state.archived.isEmpty)
    }

    @Test func changingSpaceByRestoreOrActivateCountsTheTabLeftAsViewed() throws {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.switchToSpace(work.id, now: t0)
        let workTab = state.openTab(url: url("https://work.com"), now: t0)
        state.switchToSpace(Space.defaultID, now: t0)
        let reading = state.openTab(url: url("https://a.com"), now: t0)
        state.activate(tabID: workTab.id, now: t0 + hour)
        #expect(state.tabs.first { $0.id == reading.id }?.lastViewedAt == t0 + hour)

        // A Home tab restored from the archive while in Work: back to Home.
        state.switchToSpace(Space.defaultID, now: t0 + hour)
        let old = state.openTab(url: url("https://old.com"), activate: false, now: t0 + hour)
        state.archive(tabID: old.id, now: t0 + hour)
        state.switchToSpace(work.id, now: t0 + hour)
        state.restore(archivedID: old.id, now: t0 + 2 * hour)
        #expect(state.activeSpaceID == Space.defaultID)
        #expect(state.tabs.first { $0.id == workTab.id }?.lastViewedAt == t0 + 2 * hour)
    }

    @Test func repairingTheActiveSpaceKeepsAnActiveTabAlreadyInHome() {
        let older = Tab(url: url("https://older.com"), createdAt: t0)
        let newer = Tab(url: url("https://newer.com"), createdAt: t0 + hour)
        let trip = Space(name: "Trip", archivedAt: t0)
        let kept = BrowserState(spaces: [.default, trip], tabs: [older, newer],
                                activeSpaceID: trip.id, activeTabID: older.id)
        #expect(kept.activeSpaceID == Space.defaultID && kept.activeTabID == older.id)
        let picked = BrowserState(spaces: [.default, trip], tabs: [older, newer], activeSpaceID: trip.id)
        #expect(picked.activeTabID == newer.id)
    }

    @Test func spacesToSwitchCountOnlySwitchableOnes() {
        var state = BrowserState()
        #expect(!state.hasSpacesToSwitch)
        let trip = state.addSpace(name: "Trip")
        #expect(state.hasSpacesToSwitch)
        state.archiveSpace(trip.id, now: t0)
        #expect(!state.hasSpacesToSwitch)
        state.restoreSpace(trip.id, now: t0)
        #expect(state.hasSpacesToSwitch)
        state.deleteSpace(trip.id, now: t0)
        #expect(!state.hasSpacesToSwitch)
    }

    @Test func tabCountCountsEachSpacesOpenTabs() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        _ = state.openTab(url: url("https://a.com"))
        _ = state.openTab(url: url("https://b.com"))
        let moved = state.openTab(url: url("https://c.com"), inSpace: work.id)
        #expect(state.tabCount(inSpace: Space.defaultID) == 2)
        #expect(state.tabCount(inSpace: work.id) == 1)
        #expect(state.tabCount(inSpace: UUID()) == 0)
        state.archive(tabID: moved.id, now: t0)
        #expect(state.tabCount(inSpace: work.id) == 0)
    }
}
