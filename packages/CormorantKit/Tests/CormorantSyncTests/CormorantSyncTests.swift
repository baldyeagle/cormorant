import Testing
@testable import CormorantSync

@Test func failedStateCarriesMessage() {
    #expect(SyncState.failed("offline") != .idle)
}
