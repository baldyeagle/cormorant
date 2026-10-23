import Testing
@testable import CormorantBlocking

@Test func filterListsUseHTTPS() {
    for source in FilterListSource.allCases {
        #expect(source.url.scheme == "https")
    }
}
