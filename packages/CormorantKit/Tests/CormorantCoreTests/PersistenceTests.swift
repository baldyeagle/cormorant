import Foundation
import Testing
@testable import CormorantCore

@Suite struct PersistenceTests {
    @Test func missingFileLoadsEmpty() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONBrowserStateStore(fileURL: dir.appending(path: "state.json"))
        let state = try await store.load()
        #expect(state.tabs.isEmpty)
        #expect(state.archived.isEmpty)
        #expect(state.spaces.map(\.id) == [Space.defaultID])
        #expect(state.spaces.first?.name == "Home")
        #expect(state.activeSpaceID == Space.defaultID)
        #expect(state.activeTabID == nil)
        #expect(state.schemaVersion == BrowserState.currentSchemaVersion)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "state.json").path(percentEncoded: false)))
    }

    @Test func roundTripsStateAndCreatesDirectory() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "nested/deeper/state.json")
        let store = JSONBrowserStateStore(fileURL: fileURL)

        // `.now`-based values (sub-microsecond precision) must survive exactly.
        let now = Date.now
        var state = BrowserState()
        _ = state.openTab(url: url("https://a.com/path?q=1"), title: "A", now: now)
        let b = state.openTab(url: url("https://b.com"), title: "B", now: now + 0.000_123)
        _ = state.openTab(url: nil, now: .now)
        state.tabs.append(Tab(url: url("https://pinned.com"), kind: .pinned))
        state.archive(tabID: b.id, now: .now)
        state.tabs[0].lastViewedAt = now + 1 / 3

        try await store.save(state)
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        let loaded = try await store.load()
        #expect(loaded == state)

        // Saving again overwrites.
        state.clearArchive()
        try await store.save(state)
        #expect(try await store.load() == state)
    }

    @Test func writesDatesAsReferenceDateIntervals() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "state.json")
        var state = BrowserState()
        _ = state.openTab(url: url("https://a.com"), now: t0)
        try await JSONBrowserStateStore(fileURL: fileURL).save(state)
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        // t0 is whole seconds, which JSONEncoder writes without a fraction.
        #expect(json.contains("\"createdAt\":\(Int(t0.timeIntervalSinceReferenceDate))"))
        #expect(json.contains("\"schemaVersion\":1"))
    }

    @Test func readsLegacyISO8601Dates() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "state.json")
        let tabID = UUID()
        // Written by the first builds: ISO 8601 dates, no schemaVersion.
        let json = """
        {"activeSpaceID":"\(Space.defaultID)","activeTabID":"\(tabID)","archived":[],
         "spaces":[{"createdAt":"2026-10-20T09:00:00.250Z","id":"\(Space.defaultID)","name":"Home"}],
         "tabs":[{"createdAt":"2026-10-20T09:00:00Z","id":"\(tabID)","kind":"today",
                  "lastViewedAt":"2026-10-20T10:00:00.500Z","spaceID":"\(Space.defaultID)","title":"A","url":"https://a.com"}]}
        """
        try Data(json.utf8).write(to: fileURL)
        let state = try await JSONBrowserStateStore(fileURL: fileURL).load()
        let base = try Date("2026-10-20T09:00:00Z", strategy: .iso8601)
        #expect(state.schemaVersion == 1)
        #expect(state.spaces.first?.createdAt == base + 0.25)
        #expect(state.tabs.first?.createdAt == base)
        #expect(state.tabs.first?.lastViewedAt == base + hour + 0.5)
    }

    @Test func oldFormatWithoutNewerFieldsDecodes() throws {
        let tabID = UUID()
        let archivedID = UUID()
        // Pre-Spaces shape: no schemaVersion, no activeSpaceID, no spaceID, no Space.createdAt, no kind.
        let json = """
        {"spaces":[{"id":"\(Space.defaultID)","name":"Home"}],
         "tabs":[{"id":"\(tabID)","url":"https://a.com","title":"A","createdAt":"2026-10-20T09:00:00Z",
                  "lastViewedAt":"2026-10-20T09:00:00Z"}],
         "archived":[{"id":"\(archivedID)","url":"https://b.com","title":"B","archivedAt":"2026-10-20T09:00:00Z",
                      "originalCreatedAt":"2026-10-19T09:00:00Z"}],
         "activeTabID":"\(tabID)"}
        """
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.schemaVersion == 1)
        #expect(state.activeSpaceID == Space.defaultID)
        #expect(state.activeTabID == tabID)
        #expect(state.spaces.first?.createdAt == .distantPast)
        let tab = try #require(state.tabs.first)
        #expect(tab.id == tabID && tab.spaceID == Space.defaultID && tab.kind == .today && tab.title == "A")
        let entry = try #require(state.archived.first)
        #expect(entry.id == archivedID && entry.spaceID == Space.defaultID && entry.url == url("https://b.com"))

        // Bare minimum objects decode too.
        let minimal = try CoreJSON.decoder().decode(BrowserState.self, from: Data("{\"tabs\":[{\"id\":\"\(tabID)\"}]}".utf8))
        #expect(minimal.spaces.map(\.id) == [Space.defaultID])
        #expect(minimal.tabs.first?.url == nil)
        #expect(minimal.tabs.first?.createdAt == .distantPast)
    }

    @Test func encodingWritesTheCurrentSchemaVersion() throws {
        let newer = try CoreJSON.decoder().decode(BrowserState.self, from: Data("{\"schemaVersion\":7,\"futureField\":true}".utf8))
        #expect(newer.schemaVersion == 7)
        let json = try String(decoding: CoreJSON.encoder().encode(newer), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\":\(BrowserState.currentSchemaVersion)"))
        #expect(!json.contains("futureField"))
    }

    @Test func unknownTabKindDecodesAsToday() throws {
        let json = "{\"tabs\":[{\"id\":\"\(UUID())\",\"kind\":\"folder\"},{\"id\":\"\(UUID())\",\"kind\":\"pinned\"}]}"
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.tabs.map(\.kind) == [.today, .pinned])
    }

    @Test func corruptFileIsQuarantinedAndReported() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "browser-state.json")
        try Data("{not json".utf8).write(to: fileURL)
        let store = JSONBrowserStateStore(fileURL: fileURL)

        var quarantined: URL?
        do {
            _ = try await store.load()
            Issue.record("load should throw for a corrupt file")
        } catch BrowserStateStoreError.unreadable(let quarantinedTo, let underlying) {
            quarantined = quarantinedTo
            #expect(!underlying.isEmpty)
        }
        let moved = try #require(quarantined)
        #expect(moved.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(moved.lastPathComponent.hasPrefix("browser-state.corrupt-"))
        #expect(moved.pathExtension == "json")
        #expect(try Data(contentsOf: moved) == Data("{not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        // The store is usable again: a missing file loads empty, and save + load round-trips.
        #expect(try await store.load().tabs.isEmpty)
        var state = BrowserState()
        _ = state.openTab(url: url("https://fresh.com"), now: .now)
        try await store.save(state)
        #expect(try await store.load() == state)
        // The quarantined copy is untouched.
        #expect(try Data(contentsOf: moved) == Data("{not json".utf8))
    }

    @Test func secondCorruptionGetsItsOwnQuarantineFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "browser-state.json")
        let store = JSONBrowserStateStore(fileURL: fileURL)
        var destinations: Set<URL> = []
        for attempt in 0..<2 {
            try Data("garbage \(attempt)".utf8).write(to: fileURL)
            do {
                _ = try await store.load()
            } catch BrowserStateStoreError.unreadable(let quarantinedTo, _) {
                if let quarantinedTo { destinations.insert(quarantinedTo) }
            }
        }
        #expect(destinations.count == 2)
    }
}
