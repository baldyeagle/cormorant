import Foundation
import Testing
@testable import CormorantCore

/// Settings' Archive Idle Tabs switch: off in every Space at once, and back to each Space's own time.
@Suite struct AutoArchiveTests {
    /// Home at 24 hours, Work at 12 hours, Reading off on its own, Old archived at 12 hours.
    func threeSpaces() -> (state: BrowserState, work: Space, reading: Space, old: Space) {
        var state = BrowserState()
        let work = state.addSpace(name: "Work", now: t0)
        let reading = state.addSpace(name: "Reading", now: t0)
        let old = state.addSpace(name: "Old", now: t0)
        state.updateSpace(work.id) { $0.archivePolicy = .twelveHours }
        state.updateSpace(reading.id) { $0.archivePolicy = .off }
        state.updateSpace(old.id) { $0.archivePolicy = .twelveHours }
        state.archiveSpace(old.id, now: t0)
        return (state, work, reading, old)
    }

    func policies(_ state: BrowserState) -> [ArchivePolicy] { state.spaces.map(\.archivePolicy) }

    @Test func oneSpaceTurnsHomeOffAndBackToItsTime() {
        var state = BrowserState()
        state.updateSpace(Space.defaultID) { $0.archivePolicy = .twelveHours }
        #expect(state.archivesIdleTabs)

        state.stopArchivingIdleTabs()
        #expect(!state.archivesIdleTabs)
        #expect(state.activeSpace.archivePolicy == .off)

        state.resumeArchivingIdleTabs()
        #expect(state.activeSpace.archivePolicy == .twelveHours)
        #expect(state.activeSpace.archivePolicyBeforeOff == nil)
    }

    @Test func offInEverySpaceThenEachGetsItsOwnTimeBack() {
        var (state, _, _, _) = threeSpaces()
        let before = policies(state)
        #expect(before == [.oneDay, .twelveHours, .off, .twelveHours])

        state.stopArchivingIdleTabs()
        #expect(!state.archivesIdleTabs)
        // Archived Spaces too, so restoring one doesn't start it again.
        #expect(policies(state).allSatisfy { $0 == .off })

        state.resumeArchivingIdleTabs()
        // Reading was off on its own, and stays off.
        #expect(policies(state) == before)
        #expect(state.spaces.allSatisfy { $0.archivePolicyBeforeOff == nil })
    }

    @Test func turningOffTwiceKeepsTheFirstTimes() {
        var (state, work, _, _) = threeSpaces()
        state.stopArchivingIdleTabs()
        state.stopArchivingIdleTabs()
        state.resumeArchivingIdleTabs()
        #expect(state.space(work.id)?.archivePolicy == .twelveHours)
        #expect(state.activeSpace.archivePolicy == .oneDay)
    }

    @Test func aTimeChosenWhileOffTurnsItOnForThatSpaceAlone() {
        var (state, work, _, old) = threeSpaces()
        state.stopArchivingIdleTabs()
        state.updateSpace(work.id) { $0.archivePolicy = .oneDay }
        #expect(state.archivesIdleTabs)
        // Nobody else's remembered time is left to come back on its own later.
        #expect(state.spaces.allSatisfy { $0.archivePolicyBeforeOff == nil })
        #expect(policies(state) == [.off, .oneDay, .off, .off])

        // Off and on again brings back what was on just now: Work alone.
        state.stopArchivingIdleTabs()
        state.resumeArchivingIdleTabs()
        #expect(policies(state) == [.off, .oneDay, .off, .off])
        #expect(state.space(old.id)?.archivePolicy == .off)
    }

    @Test func editingOtherFieldsKeepsTheRememberedTime() {
        var (state, work, _, _) = threeSpaces()
        state.stopArchivingIdleTabs()
        state.updateSpace(work.id) { $0.name = "Job" }
        #expect(state.space(work.id)?.archivePolicyBeforeOff == .twelveHours)
    }

    @Test func turningOffTheLastTimeByHandRemembersItForTheSwitch() {
        var (state, work, reading, old) = threeSpaces()
        state.updateSpace(Space.defaultID) { $0.archivePolicy = .off }
        #expect(state.activeSpace.archivePolicyBeforeOff == nil)  // Work still archives: a choice, not the switch
        state.updateSpace(work.id) { $0.archivePolicy = .off }
        #expect(!state.archivesIdleTabs)
        #expect(state.space(work.id)?.archivePolicyBeforeOff == .twelveHours)

        // On again: Work's time back; Home and Reading, off by choice, stay off.
        state.resumeArchivingIdleTabs()
        #expect(state.activeSpace.archivePolicy == .off)
        #expect(state.space(work.id)?.archivePolicy == .twelveHours)
        #expect(state.space(reading.id)?.archivePolicy == .off)
        #expect(state.space(old.id)?.archivePolicy == .twelveHours)
    }

    @Test func turningOnWithNothingRememberedGivesEverySpace24Hours() {
        let reading = Space(name: "Reading", archivePolicy: .off)
        let old = Space(name: "Old", archivePolicy: .twelveHours, archivedAt: t0)
        var state = BrowserState(spaces: [Space(id: Space.defaultID, name: "Home", archivePolicy: .off), reading, old])
        #expect(!state.archivesIdleTabs)

        state.resumeArchivingIdleTabs()
        #expect(state.activeSpace.archivePolicy == .oneDay)
        #expect(state.space(reading.id)?.archivePolicy == .oneDay)
        // Archived Spaces keep their own time.
        #expect(state.space(old.id)?.archivePolicy == .twelveHours)
    }

    @Test func aSavedTimeNeverReadsLikeAnOfferedOne() {
        let nearly = ArchivePolicy(interval: 86_000)
        #expect(nearly.label == "About 24 Hours")
        let labels = ArchivePolicy.choices(keeping: nearly).map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(ArchivePolicy(interval: 72 * hour).label == "3 Days")
    }

    @Test func onlySwitchableSpacesCount() {
        var (state, work, _, old) = threeSpaces()
        state.updateSpace(Space.defaultID) { $0.archivePolicy = .off }
        state.updateSpace(work.id) { $0.archivePolicy = .off }
        // Old (archived) still has twelve hours, but its tabs don't archive while it's away.
        #expect(state.space(old.id)?.archivePolicy == .twelveHours)
        #expect(!state.archivesIdleTabs)
    }

    @Test func aSpaceAddedWhileOffIsOffUntilTurnedOn() {
        var state = BrowserState()
        state.stopArchivingIdleTabs()
        let travel = state.addSpace(name: "Travel", now: t0)
        #expect(travel.archivePolicy == .off)
        #expect(!state.archivesIdleTabs)

        state.resumeArchivingIdleTabs()
        #expect(state.space(travel.id)?.archivePolicy == .oneDay)
        #expect(state.activeSpace.archivePolicy == .oneDay)

        // Otherwise a new Space gets the default.
        #expect(state.addSpace(name: "Games", now: t0).archivePolicy == .oneDay)
    }

    @Test func offArchivesNothingAndOnLeavesIdleClocksAlone() {
        var state = BrowserState()
        let active = state.openTab(url: url("https://a.com"), now: t0)
        let idle = state.openTab(url: url("https://b.com"), activate: false, now: t0)
        let now = t0 + 30 * hour

        state.stopArchivingIdleTabs()
        #expect(state.runArchive(now: now).isEmpty)
        #expect(state.tabs.map(\.id) == [active.id, idle.id])

        state.resumeArchivingIdleTabs()
        #expect(state.tabs.first { $0.id == idle.id }?.lastViewedAt == t0)
        #expect(state.tabsDue(inSpace: Space.defaultID, now: now).map(\.id) == [idle.id])
        #expect(state.runArchive(now: now).map(\.id) == [idle.id])
    }

    @Test func tabsDueFollowsThePolicyGivenOrTheSpacesOwn() {
        var (state, work, _, old) = threeSpaces()
        let home = state.openTab(url: url("https://home.com"), activate: false, now: t0 - 25 * hour)
        let idle13h = state.openTab(url: url("https://a.com"), inSpace: work.id, now: t0 - 13 * hour)
        let idle1h = state.openTab(url: url("https://b.com"), inSpace: work.id, now: t0 - hour)

        #expect(state.tabsDue(inSpace: work.id, now: t0).map(\.id) == [idle13h.id])
        #expect(state.tabsDue(inSpace: work.id, policy: .oneDay, now: t0).isEmpty)
        #expect(state.tabsDue(inSpace: work.id, policy: .off, now: t0).isEmpty)
        #expect(!state.tabsDue(inSpace: work.id, now: t0).contains { $0.id == idle1h.id })
        #expect(state.tabsDue(inSpace: Space.defaultID, now: t0).map(\.id) == [home.id])
        #expect(state.tabsDue(inSpace: old.id, policy: .twelveHours, now: t0).isEmpty)
        #expect(state.tabsDue(inSpace: UUID(), policy: .twelveHours, now: t0).isEmpty)
    }

    @Test func rememberedTimeSurvivesSavingAndUnknownShapes() throws {
        var (state, work, _, _) = threeSpaces()
        state.stopArchivingIdleTabs()
        let data = try CoreJSON.encoder().encode(state)
        let loaded = try CoreJSON.decoder().decode(BrowserState.self, from: data)
        #expect(loaded.space(work.id)?.archivePolicyBeforeOff == .twelveHours)
        #expect(loaded.space(work.id)?.archivePolicy == .off)

        // A shape this build can't read costs the remembered time, not the file; none is nil.
        func space(_ before: String) throws -> Space {
            let json = "{\"id\":\"\(UUID())\",\"name\":\"X\",\"archivePolicy\":{\"interval\":null}\(before)}"
            return try CoreJSON.decoder().decode(Space.self, from: Data(json.utf8))
        }
        #expect(try space("").archivePolicyBeforeOff == nil)
        #expect(try space(",\"archivePolicyBeforeOff\":\"weekly\"").archivePolicyBeforeOff == nil)
        #expect(try space(",\"archivePolicyBeforeOff\":{\"interval\":43200}").archivePolicyBeforeOff == .twelveHours)
        // A Space that never had one doesn't write the key, so older files look the same.
        let plain = String(decoding: try CoreJSON.encoder().encode(Space(name: "Y")), as: UTF8.self)
        #expect(!plain.contains("archivePolicyBeforeOff"))
    }

    @Test func offersArcsFourTimesThenOff() {
        #expect(ArchivePolicy.offered == [.twelveHours, .oneDay, .sevenDays, .thirtyDays, .off])
        #expect(ArchivePolicy.offered.map(\.label) == ["12 Hours", "24 Hours", "7 Days", "30 Days", "Off"])
        #expect(ArchivePolicy.sevenDays.interval == 7 * 24 * hour)
        #expect(ArchivePolicy.thirtyDays.interval == 30 * 24 * hour)
        // The default stays 24 hours.
        #expect(Space(name: "X").archivePolicy == .oneDay)
        #expect(ArchivePolicy.oneDay.interval == 24 * hour)
    }

    @Test func aTimeNotOfferedIsKeptInItsPlace() {
        let threeDays = ArchivePolicy(interval: 72 * hour)
        #expect(ArchivePolicy.choices(keeping: threeDays) == [.twelveHours, .oneDay, threeDays, .sevenDays, .thirtyDays, .off])
        #expect(ArchivePolicy.choices(keeping: ArchivePolicy(interval: 90 * 24 * hour)).last(where: { $0 != .off })?.interval
            == 90 * 24 * hour)
        #expect(ArchivePolicy.choices(keeping: .sevenDays) == ArchivePolicy.offered)
        #expect(ArchivePolicy.choices(keeping: .off) == ArchivePolicy.offered)
        #expect(threeDays.label == "3 Days")
        #expect(ArchivePolicy(interval: 36 * hour).label == "36 Hours")
        #expect(ArchivePolicy(interval: 60).label == "1 Hour")
        #expect(ArchivePolicy(interval: 1e300).label.hasSuffix("Days"))
    }

    @Test func newTimesSaveAndLoad() throws {
        var state = BrowserState()
        let work = state.addSpace(name: "Work", now: t0)
        state.updateSpace(work.id) { $0.archivePolicy = .thirtyDays }
        state.updateSpace(Space.defaultID) { $0.archivePolicy = .sevenDays }
        let loaded = try CoreJSON.decoder().decode(BrowserState.self, from: CoreJSON.encoder().encode(state))
        #expect(loaded.space(work.id)?.archivePolicy == .thirtyDays)
        #expect(loaded.activeSpace.archivePolicy == .sevenDays)

        // Seven days really waits seven days.
        let idle6d = state.openTab(url: url("https://a.com"), activate: false, now: t0)
        #expect(state.tabsDue(inSpace: Space.defaultID, now: t0 + 6 * 24 * hour).isEmpty)
        #expect(state.tabsDue(inSpace: Space.defaultID, now: t0 + 7 * 24 * hour).map(\.id) == [idle6d.id])
    }

    @Test func unusableTimesDecodeAs24Hours() throws {
        func space(_ policy: String) throws -> Space {
            let json = "{\"id\":\"\(UUID())\",\"name\":\"X\",\"archivePolicy\":\(policy)}"
            return try CoreJSON.decoder().decode(Space.self, from: Data(json.utf8))
        }
        #expect(try space("{\"interval\":0}").archivePolicy == .oneDay)
        #expect(try space("{\"interval\":-3600}").archivePolicy == .oneDay)
        #expect(try space("{\"interval\":1e21}").archivePolicy == .oneDay)
        #expect(try space("{\"interval\":259200}").archivePolicy == ArchivePolicy(interval: 72 * hour))
        #expect(try space("{\"interval\":2592000}").archivePolicy == .thirtyDays)
    }
}
