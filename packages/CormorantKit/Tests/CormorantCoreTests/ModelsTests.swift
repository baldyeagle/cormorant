import Foundation
import Testing
@testable import CormorantCore

@Suite struct ModelsTests {
    @Test func newTabDefaultsLastViewedToCreation() {
        let tab = Tab(url: URL(string: "https://example.com"), title: "Example")
        #expect(tab.lastViewedAt == tab.createdAt)
        #expect(tab.kind == .today)
    }

    @Test func displayTitleFallsBackToHostThenPlaceholder() {
        #expect(Tab(url: url("https://example.com/a"), title: "Hi").displayTitle == "Hi")
        #expect(Tab(url: url("https://example.com/a")).displayTitle == "example.com")
        #expect(Tab().displayTitle == "New Tab")
    }

    @Test func archivingABlankTabYieldsNil() throws {
        #expect(ArchivedTab(archiving: Tab(url: nil), at: t0) == nil)
        let tab = Tab(url: url("https://a.com"), title: "A", createdAt: t0)
        let entry = try #require(ArchivedTab(archiving: tab, at: t0 + hour))
        #expect(entry.id == tab.id && entry.url == tab.url && entry.archivedAt == t0 + hour && entry.originalCreatedAt == t0)
    }
}
