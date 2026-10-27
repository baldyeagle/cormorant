import Foundation
import Testing
@testable import CormorantCore

@Suite struct BrowserStateTests {
    @Test func openTabAppendsTodayTabInActiveSpaceAndActivatesIt() {
        let work = Space(name: "Work")
        var state = BrowserState(spaces: [.default, work], activeSpaceID: work.id)
        let tab = state.openTab(url: url("https://example.com"), title: "Example", now: t0)
        #expect(state.tabs == [tab])
        #expect(tab.kind == .today)
        #expect(tab.spaceID == work.id)
        #expect(tab.createdAt == t0 && tab.lastViewedAt == t0)
        #expect(state.activeTabID == tab.id)
    }

    @Test func openTabInBackgroundKeepsActiveTab() {
        var state = BrowserState()
        let active = state.openTab(url: url("https://a.com"), now: t0)
        let background = state.openTab(url: url("https://b.com"), activate: false, now: t0 + hour)
        #expect(state.tabs.map(\.id) == [active.id, background.id])
        #expect(state.activeTabID == active.id)
        #expect(background.kind == .today && background.lastViewedAt == t0 + hour)
    }

    @Test func archiveMovesTabToArchiveAndActivatesMostRecentInSameSpace() {
        var state = BrowserState()
        let older = state.openTab(url: url("https://a.com"), now: t0)
        let newer = state.openTab(url: url("https://b.com"), now: t0 + hour)
        let current = state.openTab(url: url("https://c.com"), title: "C", now: t0 + 2 * hour)
        let otherSpace = Space(name: "Other")
        state.spaces.append(otherSpace)
        state.tabs.append(Tab(spaceID: otherSpace.id, url: url("https://z.com"), createdAt: t0 + 5 * hour))

        state.archive(tabID: current.id, now: t0 + 3 * hour)

        #expect(!state.tabs.contains { $0.id == current.id })
        #expect(state.archived.count == 1)
        let entry = state.archived[0]
        #expect(entry.id == current.id)
        #expect(entry.url == url("https://c.com"))
        #expect(entry.title == "C")
        #expect(entry.archivedAt == t0 + 3 * hour)
        #expect(entry.originalCreatedAt == t0 + 2 * hour)
        #expect(state.activeTabID == newer.id)
        _ = older
    }

    @Test func archiveDropsBlankTabs() {
        var state = BrowserState()
        let blank = state.openTab(url: nil, now: t0)
        state.archive(tabID: blank.id, now: t0 + hour)
        #expect(state.tabs.isEmpty)
        #expect(state.archived.isEmpty)
        #expect(state.activeTabID == nil)
    }

    @Test func archivingBackgroundTabKeepsActiveTab() {
        var state = BrowserState()
        let background = state.openTab(url: url("https://a.com"), now: t0)
        let active = state.openTab(url: url("https://b.com"), now: t0 + hour)
        state.archive(tabID: background.id, now: t0 + 2 * hour)
        #expect(state.activeTabID == active.id)
    }

    @Test func archiveUnknownTabIsNoOp() {
        var state = BrowserState()
        _ = state.openTab(url: url("https://a.com"), now: t0)
        let before = state
        state.archive(tabID: UUID(), now: t0)
        #expect(state == before)
    }

    @Test func openTabRecordsLinkOpened() {
        var state = BrowserState()
        let typed = state.openTab(url: url("https://a.com"), now: t0)
        let linked = state.openTab(url: url("https://b.com"), fromLink: true, now: t0 + hour)
        #expect(linked.openedFromLink)
        #expect(!typed.openedFromLink)
    }

    @Test func tabAfterArchivingIsWhatArchivingActivates() {
        let other = Space(name: "Other")
        var state = BrowserState(spaces: [.default, other])
        let older = state.openTab(url: url("https://a.com"), now: t0)
        let recent = state.openTab(url: url("https://r.com"), now: t0 + hour)
        let current = state.openTab(url: url("https://b.com"), fromLink: true, now: t0 + 2 * hour)
        // More recent, but in another Space.
        state.tabs.append(Tab(spaceID: other.id, url: url("https://z.com"), createdAt: t0 + 3 * hour))
        state.tabs[state.tabs.firstIndex { $0.id == older.id }!].lastViewedAt = t0 + 30 * 60
        #expect(state.tabAfterArchiving(current.id) == recent.id)

        state.archive(tabID: current.id, now: t0 + 4 * hour)
        #expect(state.activeTabID == recent.id)
        #expect(state.tabAfterArchiving(recent.id) == older.id)
        #expect(state.tabAfterArchiving(UUID()) == nil)
    }

    @Test func tabAfterArchivingIsNilWhenNothingElseIsOpen() {
        var state = BrowserState()
        let only = state.openTab(url: url("https://b.com"), fromLink: true, now: t0)
        #expect(state.tabAfterArchiving(only.id) == nil)
        state.archive(tabID: only.id, now: t0 + hour)
        #expect(state.activeTabID == nil)
    }

    @Test func runArchiveArchivesDueTabsOnly() {
        var state = BrowserState()
        let stale = state.openTab(url: url("https://stale.com"), now: t0)
        let blank = state.openTab(url: nil, now: t0)
        var pinned = Tab(url: url("https://pinned.com"), kind: .pinned, createdAt: t0)
        pinned.lastViewedAt = t0
        state.tabs.append(pinned)
        let fresh = state.openTab(url: url("https://fresh.com"), now: t0 + 20 * hour)
        let active = state.openTab(url: url("https://active.com"), now: t0)  // active, though idle

        let archived = state.runArchive(policy: .oneDay, now: t0 + 25 * hour)

        #expect(archived.map(\.id) == [stale.id])
        #expect(state.archived.map(\.id) == [stale.id])
        #expect(Set(state.tabs.map(\.id)) == [pinned.id, fresh.id, active.id])
        #expect(!state.tabs.contains { $0.id == blank.id })
        #expect(state.activeTabID == active.id)
    }

    @Test func runArchiveWithOffPolicyDoesNothing() {
        var state = BrowserState()
        _ = state.openTab(url: url("https://a.com"), now: t0)
        _ = state.openTab(url: url("https://b.com"), now: t0)
        let before = state
        #expect(state.runArchive(policy: .off, now: t0 + 1_000 * hour).isEmpty)
        #expect(state == before)
    }

    @Test func restoreReopensAsActiveTodayTab() throws {
        var state = BrowserState()
        let original = state.openTab(url: url("https://a.com"), title: "A", now: t0)
        let other = state.openTab(url: url("https://b.com"), now: t0 + hour)
        state.archive(tabID: original.id, now: t0 + 2 * hour)
        #expect(state.activeTabID == other.id)

        let result = state.restore(archivedID: original.id, now: t0 + 3 * hour)
        let restored = try #require(result)

        #expect(state.archived.isEmpty)
        #expect(restored.url == url("https://a.com"))
        #expect(restored.title == "A")
        #expect(restored.kind == .today)
        #expect(restored.createdAt == t0 + 3 * hour)
        #expect(restored.lastViewedAt == t0 + 3 * hour)
        #expect(state.tabs.contains(restored))
        #expect(state.activeTabID == restored.id)
    }

    @Test func restoreUnknownReturnsNil() {
        var state = BrowserState()
        #expect(state.restore(archivedID: UUID(), now: t0) == nil)
    }

    @Test func activateBumpsLastViewedAndSetsActive() {
        var state = BrowserState()
        let first = state.openTab(url: url("https://a.com"), now: t0)
        _ = state.openTab(url: url("https://b.com"), now: t0 + hour)
        state.activate(tabID: first.id, now: t0 + 2 * hour)
        #expect(state.activeTabID == first.id)
        #expect(state.tabs.first { $0.id == first.id }?.lastViewedAt == t0 + 2 * hour)
        #expect(state.activeSpaceTabs.first?.id == first.id)
    }

    @Test func activateUnknownIsNoOp() {
        var state = BrowserState()
        _ = state.openTab(url: url("https://a.com"), now: t0)
        let before = state
        state.activate(tabID: UUID(), now: t0 + hour)
        #expect(state == before)
    }

    @Test func updateSetsOnlyNonNilFields() {
        var state = BrowserState()
        let tab = state.openTab(url: url("https://a.com"), title: "Old", now: t0)

        state.update(tabID: tab.id, url: url("https://a.com/next"), title: nil)
        #expect(state.tabs[0].url == url("https://a.com/next"))
        #expect(state.tabs[0].title == "Old")

        state.update(tabID: tab.id, url: nil, title: "New")
        #expect(state.tabs[0].url == url("https://a.com/next"))
        #expect(state.tabs[0].title == "New")
    }

    @Test func archiveIsCappedDroppingOldest() {
        var state = BrowserState()
        state.archived = (0..<BrowserState.archiveCapacity).map { i in
            ArchivedTab(url: url("https://old\(i).com"), title: "", archivedAt: t0 + Double(i),
                        originalCreatedAt: t0)
        }
        let tab = state.openTab(url: url("https://newest.com"), now: t0)
        state.archive(tabID: tab.id, now: t0 + 10_000)

        #expect(state.archived.count == BrowserState.archiveCapacity)
        #expect(state.archived.first?.url == url("https://old1.com"))
        #expect(state.archived.last?.url == url("https://newest.com"))
    }

    @Test func archivedByDayGroupsNewestDayFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!

        func entry(_ name: String, _ at: Date) -> ArchivedTab {
            ArchivedTab(url: url("https://\(name).com"), title: name, archivedAt: at, originalCreatedAt: at)
        }
        let a = entry("a", dayOne)
        let b = entry("b", dayOne + 5 * hour)
        let c = entry("c", dayTwo)
        let d = entry("d", dayTwo + 14 * hour)  // 23:00 on day two
        let state = BrowserState(archived: [a, c, b, d])

        let groups = state.archivedByDay(calendar: calendar)

        #expect(groups.count == 2)
        #expect(groups[0].day == calendar.startOfDay(for: dayTwo))
        #expect(groups[0].tabs.map(\.title) == ["d", "c"])
        #expect(groups[1].day == calendar.startOfDay(for: dayOne))
        #expect(groups[1].tabs.map(\.title) == ["b", "a"])
    }
}
