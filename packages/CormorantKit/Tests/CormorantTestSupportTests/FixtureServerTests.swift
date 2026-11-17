import CormorantTestSupport
import Foundation
import Testing

/// The fixture server the apps' tests load pages from: the page on every path, counted by path, and a
/// held path answered only once released.
@Suite(.timeLimit(.minutes(1))) struct FixtureServerTests {
    private static let page = "<!doctype html><title>Fixture</title><h1>Fixture</h1>"

    @Test func servesThePageOnEveryPathAndCountsRequests() async throws {
        let server = try FixtureServer(html: Self.page)
        let (data, response) = try await URLSession.shared.data(from: server.url.appending(path: "a"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == Self.page)
        _ = try await URLSession.shared.data(from: server.url.appending(path: "a"))
        _ = try await URLSession.shared.data(from: server.url.appending(path: "b"))
        #expect(server.requestCount(for: "/a") == 2)
        #expect(server.requestCount(for: "/b") == 1)
        #expect(server.requestCount(for: "/c") == 0)
        #expect(server.requestLog.contains("GET /b"))
    }

    /// A held request waits for `release`, and stays unanswered until then however long that is: the
    /// test, not a timer, decides when it lands.
    @Test func answersAHeldPathOnlyOnceReleased() async throws {
        let server = try FixtureServer(html: Self.page, holds: ["/held"])
        let held = server.url.appending(path: "held")
        let request = Task { try await URLSession.shared.data(from: held) }
        // Arrived and counted, but not answered.
        while server.requestCount(for: "/held") == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.requestCount(for: "/held") == 1)
        server.release("/held")
        let (data, _) = try await request.value
        #expect(String(decoding: data, as: UTF8.self) == Self.page)
        // Released for good: later requests are answered at once.
        _ = try await URLSession.shared.data(from: held)
        #expect(server.requestCount(for: "/held") == 2)
    }
}
