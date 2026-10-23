import Foundation
import Testing
@testable import CormorantCore

@Suite struct ArchivePolicyTests {
    let now = t0 + 48 * hour

    func tab(idle: TimeInterval, kind: TabKind = .today, url: URL? = url("https://example.com")) -> Tab {
        Tab(url: url, kind: kind, createdAt: now - idle - hour, lastViewedAt: now - idle)
    }

    @Test func returnsTodayTabsIdleAtLeastTheInterval() {
        let fresh = tab(idle: 23 * hour)
        let exact = tab(idle: 24 * hour)
        let stale = tab(idle: 30 * hour)
        let due = ArchivePolicy.oneDay.tabsDue(in: [fresh, exact, stale], activeTabID: nil, now: now)
        #expect(due.map(\.id) == [exact.id, stale.id])
    }

    @Test func excludesTheActiveTab() {
        let stale = tab(idle: 30 * hour)
        let other = tab(idle: 30 * hour)
        let due = ArchivePolicy.oneDay.tabsDue(in: [stale, other], activeTabID: stale.id, now: now)
        #expect(due.map(\.id) == [other.id])
    }

    @Test func excludesPinnedTabs() {
        let pinned = tab(idle: 100 * hour, kind: .pinned)
        #expect(ArchivePolicy.oneDay.tabsDue(in: [pinned], activeTabID: nil, now: now).isEmpty)
    }

    @Test func offPolicyNeverArchives() {
        let stale = tab(idle: 1_000 * hour)
        #expect(ArchivePolicy.off.tabsDue(in: [stale], activeTabID: nil, now: now).isEmpty)
    }

    @Test func includesBlankTabsSoTheyAreDropped() {
        let blank = tab(idle: 13 * hour, url: nil)
        let due = ArchivePolicy.twelveHours.tabsDue(in: [blank], activeTabID: nil, now: now)
        #expect(due.map(\.id) == [blank.id])
    }
}
