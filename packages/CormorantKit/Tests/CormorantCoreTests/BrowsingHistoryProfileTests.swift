import Foundation
import SQLite3
import Testing
@testable import CormorantCore

@Suite struct BrowsingHistoryProfileTests {
    private let work = UUID()

    // MARK: Scoped queries

    @Test func suggestionsComeFromOneProfile() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://home.example/recipes"), title: "Recipes", at: t0)
        await store.recordVisit(to: url("https://linear.app/issues"), title: "Issues", profile: work, at: t0)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=tile"), searchQuery: "tile", at: t0)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=triage"), searchQuery: "triage", profile: work, at: t0)

        #expect(await store.pages(matching: "recipes", now: t0).count == 1)
        #expect(await store.pages(matching: "recipes", profile: work, now: t0).isEmpty)
        #expect(await store.pages(matching: "issues", profile: work, now: t0).map(\.title) == ["Issues"])
        #expect(await store.pages(matching: "issues", now: t0).isEmpty)

        #expect(await store.searches(matching: "t", now: t0) == ["tile"])
        #expect(await store.searches(matching: "t", profile: work, now: t0) == ["triage"])

        #expect(await store.completionHosts(now: t0).contains("home.example"))
        #expect(!(await store.completionHosts(now: t0).contains("linear.app")))
        #expect(await store.completionHosts(profile: work, now: t0).contains("linear.app"))
        #expect(!(await store.completionHosts(profile: work, now: t0).contains("home.example")))
    }

    @Test func theSamePageIsCountedPerProfile() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://github.com/"), title: "GitHub", at: t0)
        await store.recordVisit(to: url("https://github.com/"), title: "GitHub", typed: true, profile: work, at: t0)
        await store.recordVisit(to: url("https://github.com/"), profile: work, at: t0 + hour)
        #expect(await store.pageCount == 2)
        #expect(await store.pageCount(profile: work) == 1)
        let home = try #require(await store.pages(matching: "github", now: t0 + hour).first)
        let mine = try #require(await store.pages(matching: "github", profile: work, now: t0 + hour).first)
        #expect(home.visitCount == 1 && home.typedCount == 0)
        #expect(mine.visitCount == 2 && mine.typedCount == 1)
    }

    @Test func titlesUpdateInTheirProfileOnly() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://a.example/"), title: "Old", at: t0)
        await store.recordVisit(to: url("https://a.example/"), title: "Old", profile: work, at: t0)
        await store.updateTitle("New", for: url("https://a.example/"), profile: work)
        #expect(await store.pages(matching: "a.example", now: t0).map(\.title) == ["Old"])
        #expect(await store.pages(matching: "a.example", profile: work, now: t0).map(\.title) == ["New"])
    }

    @Test func removingAProfileLeavesTheOthers() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://a.example/"), at: t0)
        await store.recordVisit(to: url("https://a.example/"), profile: work, at: t0)
        await store.recordVisit(to: url("https://b.example/"), profile: work, at: t0)
        #expect(await store.profiles() == [Profile.defaultID, work])
        #expect(await store.removeProfile(work))
        #expect(await store.pageCount == 1)
        #expect(await store.pageCount(profile: work) == 0)
        #expect(await store.profiles() == [Profile.defaultID])
    }

    /// Settings' Clear History clears every profile.
    @Test(arguments: [false, true]) func clearingSpansEveryProfile(all: Bool) async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://a.example/"), at: t0)
        await store.recordVisit(to: url("https://b.example/"), profile: work, at: t0)
        if all { await store.removeAll() } else { await store.removePages(visitedSince: t0) }
        #expect(await store.pageCount == 0)
    }

    @Test func removingAPageWithoutAProfileRemovesItEverywhere() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://a.example/"), at: t0)
        await store.recordVisit(to: url("https://a.example/"), profile: work, at: t0)
        await store.removePage(url("https://a.example/"), profile: work)
        #expect(await store.pageCount == 1)
        await store.removePage(url("https://a.example/"))
        #expect(await store.pageCount == 0)
    }

    // MARK: Migration from schema 1

    /// A database from before profiles: every page moves to the default profile, with its counts,
    /// title, query and dates as they were, and suggestions from it work as before.
    @Test func versionOnePagesBecomeTheDefaultProfiles() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.sqlite")
        try writeVersionOneDatabase(at: file)

        let store = try BrowsingHistory(fileURL: file)
        #expect(await store.pageCount == 2)
        #expect(await store.pageCount(profile: Profile.defaultID) == 2)
        #expect(await store.profiles() == [Profile.defaultID])
        let entry = try #require(await store.pages(matching: "example", now: t0).first)
        #expect(entry.title == "Example")
        #expect(entry.visitCount == 3)
        #expect(entry.typedCount == 1)
        #expect(entry.lastVisitedAt == t0)
        #expect(await store.searches(matching: "tile", now: t0) == ["tile"])
        #expect(await store.pages(matching: "example", profile: work, now: t0).isEmpty)

        // New visits merge into the migrated rows rather than adding a second copy.
        await store.recordVisit(to: url("https://example.com/"), at: t0 + hour)
        #expect(await store.pageCount == 2)
        #expect(try #require(await store.pages(matching: "example", now: t0 + hour).first).visitCount == 4)
        // And the same page in another profile is its own row.
        await store.recordVisit(to: url("https://example.com/"), profile: work, at: t0 + hour)
        #expect(await store.pageCount == 3)
        #expect(try userVersion(of: file) == 2)
    }

    @Test func migratedDatabasesReopen() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.sqlite")
        try writeVersionOneDatabase(at: file)
        do {
            let store = try BrowsingHistory(fileURL: file)
            await store.recordVisit(to: url("https://linear.app/"), profile: work, at: t0)
        }
        let reopened = try BrowsingHistory(fileURL: file)
        #expect(await reopened.pageCount == 3)
        #expect(await reopened.pageCount(profile: work) == 1)
    }

    @Test func newDatabasesStartAtTheCurrentVersion() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.sqlite")
        do { _ = try BrowsingHistory(fileURL: file) }
        #expect(try userVersion(of: file) == BrowsingHistory.schemaVersion)
    }

    // MARK: Helpers

    /// The schema-1 table as the first build with history made it, with two pages.
    private func writeVersionOneDatabase(at file: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path(percentEncoded: false), &db) == SQLITE_OK else { throw Failure() }
        defer { sqlite3_close(db) }
        let when = t0.timeIntervalSinceReferenceDate
        let sql = """
            CREATE TABLE places (
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                url TEXT NOT NULL,
                host TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                search_query TEXT,
                search_key TEXT,
                match_text TEXT NOT NULL,
                visit_count INTEGER NOT NULL DEFAULT 0,
                typed_count INTEGER NOT NULL DEFAULT 0,
                last_visit REAL NOT NULL
            );
            CREATE INDEX places_host ON places (host);
            CREATE INDEX places_last_visit ON places (last_visit);
            INSERT INTO places (key, url, host, title, match_text, visit_count, typed_count, last_visit)
                VALUES ('example.com', 'https://example.com/', 'example.com', 'Example', 'example.com example', 3, 1, \(when));
            INSERT INTO places (key, url, host, title, search_query, search_key, match_text, visit_count, typed_count, last_visit)
                VALUES ('duckduckgo.com?q=tile', 'https://duckduckgo.com/?q=tile', 'duckduckgo.com', '', 'tile', 'tile',
                        'duckduckgo.com?q=tile ', 1, 0, \(when));
            PRAGMA user_version = 1;
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure() }
    }

    private func userVersion(of file: URL) throws -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(file.path(percentEncoded: false), &db) == SQLITE_OK else { throw Failure() }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw Failure() }
        return sqlite3_column_int(statement, 0)
    }

    private struct Failure: Error {}
}
