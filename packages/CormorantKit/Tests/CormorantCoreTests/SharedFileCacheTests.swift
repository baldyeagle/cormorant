import Foundation
import Testing
@testable import CormorantCore

@Suite struct SharedFileCacheTests {
    private let directory = URL.temporaryDirectory.appending(path: "Shared Files \(UUID().uuidString)")
    private let chart = URL(string: "https://aeronav.faa.gov/visual/10-29-2026/PDFs/Seattle.pdf")!

    private func file(version: String? = "etag:\"1\"", length: Int64? = 4) -> PageFile {
        PageFile(url: chart, mimeType: "application/pdf", suggestedFilename: "Seattle.pdf", version: version, expectedLength: length)!
    }

    /// Fetches `file` into `cache` as a fetch would: into the partial folder, then kept.
    @discardableResult
    private func fetch(_ file: PageFile, into cache: SharedFileCache, body: String = "%PDF") throws -> URL {
        let partial = try cache.partialFile(for: file)
        try Data(body.utf8).write(to: partial)
        return try cache.keep(partial, for: file)
    }

    @Test func aFetchedFileIsThereNextTime() throws {
        let cache = SharedFileCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(cache.cached(file()) == nil)
        let kept = try fetch(file(), into: cache)
        #expect(kept.lastPathComponent == "Seattle.pdf")
        #expect(cache.cached(file()) == kept)
        #expect(try String(contentsOf: kept, encoding: .utf8) == "%PDF")
    }

    @Test func aHalfFetchedFileIsNot() throws {
        let cache = SharedFileCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = try cache.partialFile(for: file())
        try Data("%PD".utf8).write(to: partial)
        #expect(cache.cached(file()) == nil)
        cache.discard(partial)
        #expect(!FileManager.default.fileExists(atPath: partial.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test func anotherEditionOrSizeIsFetchedAgain() throws {
        let cache = SharedFileCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fetch(file(), into: cache)
        #expect(cache.cached(file(version: "etag:\"2\"")) == nil)
        #expect(cache.cached(file(length: 5)) == nil)
    }

    /// A relaunch keeps a file with an edition; one without may have changed, so it goes.
    @Test func aRelaunchKeepsOnlyFilesWithAnEdition() throws {
        let first = SharedFileCache(directory: directory, launch: "one")
        defer { try? FileManager.default.removeItem(at: directory) }
        try fetch(file(), into: first)
        try fetch(file(version: nil), into: first)
        _ = try first.partialFile(for: file(version: "etag:\"3\""))
        #expect(first.cached(file(version: nil)) != nil)

        let second = SharedFileCache(directory: directory, launch: "two")
        second.pruneAtLaunch()
        #expect(second.cached(file()) != nil)
        #expect(second.cached(file(version: nil)) == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(left.count == 1, "\(left)")
    }

    @Test func oldAndOverBudgetCopiesGoButTheNewestStays() throws {
        let cache = SharedFileCache(directory: directory, maxAge: 3 * 3600, budget: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = file(version: "etag:\"a\"")
        let b = file(version: "etag:\"b\"")
        let c = file(version: "etag:\"c\"")
        try fetch(a, into: cache, body: "aaaa")
        try usedAgo(4 * 3600, a, in: cache)
        try fetch(b, into: cache, body: "bbbbbbbb")
        #expect(cache.cached(a) == nil, "an hour past its age")
        #expect(cache.cached(b) != nil)
        try usedAgo(3600, b, in: cache)

        try fetch(c, into: cache, body: "cccccccccccc") // 12 bytes, over the budget alone
        #expect(cache.cached(c) != nil, "the newest went")
        #expect(cache.cached(b) == nil, "over budget, an older one stayed")
    }

    /// One shared a minute ago may still be going out through a share sheet: over budget, it stays.
    @Test func aCopyJustSharedStaysOverBudget() throws {
        let cache = SharedFileCache(directory: directory, budget: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = file(version: "etag:\"a\"")
        let b = file(version: "etag:\"b\"")
        try fetch(a, into: cache, body: "aaaaaaaa")
        try usedAgo(60, a, in: cache)
        try fetch(b, into: cache, body: "bbbbbbbb")
        let folders = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(folders.count == 2, "\(folders)")
    }

    private func usedAgo(_ seconds: TimeInterval, _ file: PageFile, in cache: SharedFileCache) throws {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-seconds)],
                                              ofItemAtPath: directory.appending(path: cache.key(for: file)).path(percentEncoded: false))
    }
}
