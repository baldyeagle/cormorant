import Foundation
import Testing
@testable import CormorantCore

@Test func newTabDefaultsLastViewedToCreation() {
    let tab = Tab(url: URL(string: "https://example.com"), title: "Example")
    #expect(tab.lastViewedAt == tab.createdAt)
    #expect(tab.kind == .today)
}
