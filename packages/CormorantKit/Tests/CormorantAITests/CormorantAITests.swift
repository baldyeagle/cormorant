import Testing
@testable import CormorantAI

private struct StubProvider: AIProvider {
    let id = "stub"
    let displayName = "Stub"
    let supportedAuth: [AuthStrategy] = [.onDevice]
}

@Test func providerExposesAuthStrategies() {
    #expect(StubProvider().supportedAuth == [.onDevice])
}
