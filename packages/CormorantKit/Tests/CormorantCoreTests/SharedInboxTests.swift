import Foundation
import Testing
@testable import CormorantCore

@Suite struct SharedInboxTests {
    @Test func drainOfMissingFileIsEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = SharedInbox(fileURL: dir.appending(path: "inbox.json"))
        #expect(try inbox.drain().isEmpty)
    }

    @Test func appendThenDrainReturnsOldestFirstAndEmpties() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "group/inbox.json")
        let inbox = SharedInbox(fileURL: fileURL)

        let second = OpenRequest(url: url("https://b.com"), receivedAt: t0 + hour)
        let first = OpenRequest(url: url("https://a.com"), receivedAt: t0)
        let third = OpenRequest(url: url("https://c.com/x?y=1"), receivedAt: t0 + 2 * hour)
        try inbox.append(second)
        try inbox.append(first)
        try inbox.append(third)
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        #expect(try inbox.drain() == [first, second, third])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        #expect(try inbox.drain().isEmpty)
    }

    @Test func separateInstancesShareTheFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "inbox.json")
        let request = OpenRequest(url: url("https://shared.com"), receivedAt: t0)
        try SharedInbox(fileURL: fileURL).append(request)
        #expect(try SharedInbox(fileURL: fileURL).drain() == [request])
    }

    @Test func corruptInboxThrowsAndRecovers() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "inbox.json")
        try Data("garbage".utf8).write(to: fileURL)
        let inbox = SharedInbox(fileURL: fileURL)
        #expect(throws: (any Error).self) { try inbox.drain() }
        #expect(try inbox.drain().isEmpty)
    }

    /// Two writers append while a reader drains repeatedly: every request arrives exactly once.
    @Test(.timeLimit(.minutes(1)))
    func concurrentAppendsAndDrainsDeliverEachRequestExactlyOnce() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "inbox.json")
        let perWriter = 100

        let writer = { @Sendable (label: String) throws -> [UUID] in
            let inbox = SharedInbox(fileURL: fileURL)
            return try (0..<perWriter).map { index in
                let request = OpenRequest(url: url("https://\(label).com/\(index)"))
                try inbox.append(request)
                return request.id
            }
        }
        let writers = [Task.detached { try writer("a") }, Task.detached { try writer("b") }]
        let drainer = Task.detached { () throws -> [UUID] in
            let inbox = SharedInbox(fileURL: fileURL)
            var delivered: [UUID] = []
            while delivered.count < 2 * perWriter {
                delivered += try inbox.drain().map(\.id)
                await Task.yield()
            }
            return delivered
        }

        var appended: [UUID] = []
        for task in writers { appended += try await task.value }
        let delivered = try await drainer.value + (try SharedInbox(fileURL: fileURL).drain().map(\.id))

        #expect(appended.count == 2 * perWriter)
        #expect(delivered.count == 2 * perWriter)
        #expect(Set(delivered) == Set(appended))
        #expect(Set(delivered).count == delivered.count)
    }
}
