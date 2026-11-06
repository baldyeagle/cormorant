import Foundation
import SQLite3

/// A visited page, one per normalized URL (see `BrowsingHistory.key(for:)`).
public struct HistoryEntry: Hashable, Sendable {
    /// The most recently visited form of the URL.
    public let url: URL
    public let title: String
    public let visitCount: Int
    /// Times the user went to this page from the address field (typed it, or picked it from suggestions).
    public let typedCount: Int
    public let lastVisitedAt: Date
    /// The normalized URL that identifies this entry; matches other entries' keys for the same page.
    public let key: String

    public var displayTitle: String { title.isEmpty ? (url.host() ?? url.absoluteString) : title }
}

/// Text to append after what the user typed, shown selected so the next keystroke replaces it.
public struct InlineCompletion: Hashable, Sendable {
    /// What the user typed, unchanged.
    public let typed: String
    /// The rest of the host. Never empty.
    public let suffix: String

    public var text: String { typed + suffix }

    public init(typed: String, suffix: String) {
        self.typed = typed
        self.suffix = suffix
    }

    /// Completes `typed` to the first of `hosts` (best first, as `BrowsingHistory.completionHosts`
    /// returns them) that starts with it, ignoring case and a leading `www.` (which stays as typed).
    /// Nil when `typed` is empty, has whitespace, `/`, `?`, `#`, `:` or `@` in it, or the best match
    /// is exactly what was typed.
    public init?(completing typed: String, from hosts: [String]) {
        guard !typed.isEmpty, !typed.contains(where: { $0.isWhitespace || "/?#:@".contains($0) }) else { return nil }
        var prefix = typed.lowercased()
        if prefix.hasPrefix("www.") { prefix.removeFirst(4) }
        guard !prefix.isEmpty, let host = hosts.first(where: { $0.hasPrefix(prefix) }), host.count > prefix.count
        else { return nil }
        self.init(typed: typed, suffix: String(host.dropFirst(prefix.count)))
    }
}

public enum BrowsingHistoryError: Error, Sendable, Equatable {
    case sqlite(code: Int32, message: String)
    /// The database was written by a newer build. It's left alone.
    case newerSchema(Int32)
}

/// Browsing history in a local SQLite database, for address-field suggestions and inline completion.
///
/// Keep the file outside the app-group container: iOS kills a suspended app that holds a lock on a
/// file there (0xdead10cc), and SQLite takes locks on every write.
///
/// One row per page (`key(for:)`) per profile, counting visits and typed visits, plus the search query
/// when the page is a search engine's results. Ranking is frecency: visit counts, with typed visits
/// counting extra, weighted by how recent the last visit was.
///
/// History follows the profile, as its website data does: each visit is recorded under the profile of
/// the tab it happened in, and suggestions come from one profile's pages only. Pages recorded before
/// profiles existed (schema 1) belong to the default profile. Clearing history and pruning span every
/// profile.
public actor BrowsingHistory {
    /// Most pages kept; the least recently visited go first.
    public static let capacity = 20_000
    /// Longest URL recorded; longer ones (inline data, tracking blobs) aren't worth suggesting.
    static let maxURLLength = 4_096
    static let maxTitleLength = 512
    static let schemaVersion: Int32 = 2

    private let db: OpaquePointer
    /// Nil for an in-memory database.
    private let fileURL: URL?

    /// Opens (creating if needed) the database at `fileURL`, or an in-memory one when nil.
    /// A file SQLite reports as corrupt is moved aside to `<name>.corrupt-<timestamp>` and a fresh
    /// one is started; history is worth less than a working address field.
    public init(fileURL: URL?) throws {
        self.fileURL = fileURL
        if let fileURL {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                db = try Self.open(fileURL.path(percentEncoded: false))
            } catch BrowsingHistoryError.sqlite(let code, _) where code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
                Self.quarantine(fileURL)
                db = try Self.open(fileURL.path(percentEncoded: false))
            }
        } else {
            db = try Self.open(":memory:")
        }
    }

    isolated deinit {
        sqlite3_close_v2(db)
    }

    // MARK: Recording

    /// Counts a visit to `url` (http and https only; other schemes are ignored).
    ///
    /// - Parameters:
    ///   - title: replaces the stored title when non-empty.
    ///   - typed: the user went here from the address field (typed it, or picked it from suggestions),
    ///     which ranks it higher.
    ///   - searchQuery: set when `url` is a search engine's results page (`SearchEngine.query(in:)`);
    ///     such pages suggest their query rather than themselves.
    ///   - profile: the profile of the tab the visit happened in.
    public func recordVisit(to url: URL, title: String = "", searchQuery: String? = nil, typed: Bool = false,
                            profile: UUID = Profile.defaultID, at date: Date = .now) {
        upsert(url, title: title, searchQuery: searchQuery, visits: 1, typed: typed ? 1 : 0, profile: profile, at: date)
    }

    /// Sets the title of the page at `url` in `profile`, if it's in history there and `title` isn't empty.
    public func updateTitle(_ title: String, for url: URL, profile: UUID = Profile.defaultID) {
        let title = Self.clean(title)
        guard !title.isEmpty, let key = Self.key(for: url) else { return }
        run("UPDATE places SET title = ?1, match_text = ?2 WHERE key = ?3 AND profile = ?4 AND title != ?1",
            [.text(title), .text(Self.matchText(key: key, title: title)), .text(key), .profile(profile)])
    }

    /// Forgets pages last visited at or after `date`. Copies of a database once set aside as corrupt
    /// go too: they may hold pages from that time.
    public func removePages(visitedSince date: Date) {
        run("DELETE FROM places WHERE last_visit >= ?1", [.double(date.timeIntervalSinceReferenceDate)])
        scrubDeletedData()
        if let fileURL { Self.removeQuarantined(beside: fileURL) }
    }

    /// Forgets the page at `url`: in `profile`, or in every profile when that's nil.
    public func removePage(_ url: URL, profile: UUID? = nil) {
        guard let key = Self.key(for: url) else { return }
        if let profile {
            run("DELETE FROM places WHERE key = ?1 AND profile = ?2", [.text(key), .profile(profile)])
        } else {
            run("DELETE FROM places WHERE key = ?1", [.text(key)])
        }
    }

    /// Forgets every page visited in `profile` (a deleted profile's history goes with it). Returns
    /// whether the pages are gone, so a caller can try again later.
    @discardableResult
    public func removeProfile(_ profile: UUID) -> Bool {
        let removed = change("DELETE FROM places WHERE profile = ?1", [.profile(profile)])
        scrubDeletedData()
        return removed
    }

    /// The profiles that have pages in history.
    public func profiles() -> Set<UUID> {
        Set(query("SELECT DISTINCT profile FROM places", []) { UUID(uuidString: Self.text($0, 0)) }.compactMap { $0 })
    }

    /// Forgets everything, including copies of a database once set aside as corrupt.
    public func removeAll() {
        run("DELETE FROM places")
        run("VACUUM")
        scrubDeletedData()
        if let fileURL { Self.removeQuarantined(beside: fileURL) }
    }

    /// Deleted rows are zeroed as they go (`secure_delete`); this also empties the write-ahead log,
    /// which still holds the pages as they were.
    private func scrubDeletedData() {
        run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Drops the least recently visited pages beyond `capacity`.
    public func prune(capacity: Int = BrowsingHistory.capacity) {
        run("""
            DELETE FROM places WHERE id NOT IN (
                SELECT id FROM places ORDER BY last_visit DESC LIMIT ?1
            )
            """, [.int(Int64(capacity))])
    }

    /// One visited URL per host and scheme: the sites history still knows about. (Site icons are
    /// cached per scheme, since an http page's icon can differ from its https one.)
    public func sites() -> [URL] {
        query("SELECT url FROM places GROUP BY host, url LIKE 'https:%'", []) { URL(string: Self.text($0, 0)) }
            .compactMap { $0 }
    }

    /// Pages in every profile.
    public var pageCount: Int {
        query("SELECT count(*) FROM places", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    /// Pages in `profile`.
    public func pageCount(profile: UUID) -> Int {
        query("SELECT count(*) FROM places WHERE profile = ?1", [.profile(profile)]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    // MARK: Suggestions

    /// Pages whose URL or title contains every word of `text`, best first. Search results pages are
    /// left out (they're suggested as `searches(matching:)`).
    ///
    /// Frecency picks the candidates; among them, a host that starts with the first word ranks above
    /// a title word that does, which ranks above a match anywhere.
    public func pages(matching text: String, profile: UUID = Profile.defaultID, limit: Int = 6,
                      now: Date = .now) -> [HistoryEntry] {
        let words = Self.words(in: text)
        guard !words.isEmpty, limit > 0 else { return [] }
        let filter = words.indices.map { "instr(match_text, ?\($0 + 4)) > 0" }.joined(separator: " AND ")
        let candidates = query("""
            SELECT url, title, visit_count, typed_count, last_visit, key, host, \(Self.frecency) AS score
            FROM places
            WHERE profile = ?3 AND search_key IS NULL AND visit_count > 0 AND \(filter)
            ORDER BY score DESC, last_visit DESC
            LIMIT ?2
            """, [.double(now.timeIntervalSinceReferenceDate), .int(Int64(max(limit * 8, 48))), .profile(profile)]
                + words.map { .text($0) }
        ) { row -> (entry: HistoryEntry, host: String, score: Double)? in
            guard let entry = Self.entry(row) else { return nil }
            return (entry, Self.text(row, 6), sqlite3_column_double(row, 7))
        }.compactMap { $0 }

        let first = words[0]
        func boost(_ candidate: (entry: HistoryEntry, host: String, score: Double)) -> Double {
            if candidate.host.hasPrefix(first) { return 4 }
            let titleWords = candidate.entry.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if titleWords.contains(where: { $0.hasPrefix(first) }) { return 2 }
            return 1
        }
        return candidates
            .enumerated()
            // Stable: equal scores keep SQL's order (frecency, then recency).
            .sorted { lhs, rhs in
                let l = lhs.element.score * boost(lhs.element), r = rhs.element.score * boost(rhs.element)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map(\.element.entry)
    }

    /// Past search queries containing every word of `text`, best first: queries that start with
    /// `text` before others, then by frecency. Case-insensitive and de-duplicated; each query is
    /// returned as it was last typed.
    public func searches(matching text: String, profile: UUID = Profile.defaultID, limit: Int = 4,
                         now: Date = .now) -> [String] {
        let words = Self.words(in: text, stripURLPrefix: false)
        guard !words.isEmpty, limit > 0 else { return [] }
        let prefix = words.joined(separator: " ")
        let filter = words.indices.map { "instr(search_key, ?\($0 + 5)) > 0" }.joined(separator: " AND ")
        return query("""
            SELECT search_query FROM (
                SELECT search_query, search_key, last_visit,
                       row_number() OVER (PARTITION BY search_key ORDER BY last_visit DESC) AS n,
                       sum(\(Self.frecency)) OVER (PARTITION BY search_key) AS total
                FROM places WHERE profile = ?4 AND search_key IS NOT NULL
            )
            WHERE n = 1 AND \(filter)
            ORDER BY substr(search_key, 1, length(?3)) = ?3 DESC, total DESC, last_visit DESC
            LIMIT ?2
            """, [.double(now.timeIntervalSinceReferenceDate), .int(Int64(limit)), .text(prefix), .profile(profile)]
                + words.map { .text($0) }
        ) { Self.text($0, 0) }
    }

    /// Visited hosts (without `www.`, with any port other than the default), highest frecency first,
    /// for `InlineCompletion(completing:from:)`. Loaded once when the address field opens, so
    /// completing a keystroke never waits on the database.
    public func completionHosts(profile: UUID = Profile.defaultID, limit: Int = 5_000, now: Date = .now) -> [String] {
        // The key up to its path or query: the host, and the port if it has one.
        query("""
            SELECT substr(key, 1, min(instr(key || '/', '/'), instr(key || '?', '?')) - 1) AS site
            FROM places
            WHERE profile = ?3 AND search_key IS NULL AND visit_count > 0
            GROUP BY site
            ORDER BY sum(\(Self.frecency)) DESC, max(last_visit) DESC
            LIMIT ?2
            """, [.double(now.timeIntervalSinceReferenceDate), .int(Int64(limit)), .profile(profile)]
        ) { Self.text($0, 0) }
    }

    // MARK: Keys

    /// Identifies a page across trivial URL differences: no scheme (http and https are the same page),
    /// lowercase host without `www.` or a trailing dot, default ports dropped, no userinfo, no
    /// trailing `/`, no fragment. Query strings are kept. Nil for anything but http(s) with a host.
    public static func key(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = normalizedHost(url) else { return nil }
        var key = host
        if let port = url.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) {
            key += ":\(port)"
        }
        var path = url.path(percentEncoded: true)
        if path.hasSuffix("/") { path.removeLast() }
        key += path
        if let query = url.query(percentEncoded: true), !query.isEmpty { key += "?" + query }
        return key
    }

    /// Lowercase host without `www.` or a trailing dot.
    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host(percentEncoded: true)?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    // MARK: Private

    /// Weighted visit count: typed visits count three times, scaled by the age of the last visit.
    /// `?1` is now, as seconds since the reference date.
    private static let frecency = """
        ((visit_count + 2 * typed_count) * CASE
            WHEN ?1 - last_visit < 4 * 86400 THEN 100
            WHEN ?1 - last_visit < 14 * 86400 THEN 70
            WHEN ?1 - last_visit < 31 * 86400 THEN 50
            WHEN ?1 - last_visit < 90 * 86400 THEN 30
            ELSE 10 END)
        """

    private func upsert(_ url: URL, title: String, searchQuery: String?, visits: Int, typed: Int, profile: UUID,
                        at date: Date) {
        guard let key = Self.key(for: url), let host = Self.normalizedHost(url),
              let stored = Self.withoutCredentials(url), stored.absoluteString.utf8.count <= Self.maxURLLength
        else { return }
        let title = Self.clean(title)
        let searchQuery = searchQuery.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        let searchKey = searchQuery.map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        // An empty title (a typed visit, a page that hasn't reported one yet) keeps the stored one.
        run("""
            INSERT INTO places (key, url, host, title, search_query, search_key, match_text,
                                visit_count, typed_count, last_visit, profile)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ON CONFLICT (profile, key) DO UPDATE SET
                url = excluded.url,
                title = CASE WHEN excluded.title != '' THEN excluded.title ELSE title END,
                match_text = CASE WHEN excluded.title != '' THEN excluded.match_text ELSE match_text END,
                search_query = coalesce(excluded.search_query, search_query),
                search_key = coalesce(excluded.search_key, search_key),
                visit_count = visit_count + excluded.visit_count,
                typed_count = typed_count + excluded.typed_count,
                last_visit = max(last_visit, excluded.last_visit)
            """, [
                .text(key), .text(stored.absoluteString), .text(host), .text(title),
                searchQuery.map { .text($0) } ?? .null, searchKey.map { .text($0) } ?? .null,
                .text(Self.matchText(key: key, title: title)),
                .int(Int64(visits)), .int(Int64(typed)), .double(date.timeIntervalSinceReferenceDate),
                .profile(profile),
            ])
    }

    private static func withoutCredentials(_ url: URL) -> URL? {
        guard url.user(percentEncoded: true) != nil || url.password(percentEncoded: true) != nil else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// What `pages(matching:)` searches. Lowercased here rather than with SQLite's `lower()`,
    /// which only folds ASCII.
    private static func matchText(key: String, title: String) -> String {
        (key + " " + title).lowercased()
    }

    /// Single-line, trimmed, capped.
    private static func clean(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(maxTitleLength))
    }

    /// Lowercased words of `text`, at most eight. A leading scheme and `www.` are dropped from the
    /// first, since keys and match text have neither.
    static func words(in text: String, stripURLPrefix: Bool = true) -> [String] {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).prefix(8).map(String.init)
        if stripURLPrefix, var first = words.first {
            for prefix in ["https://", "http://"] where first.hasPrefix(prefix) { first.removeFirst(prefix.count) }
            if first.hasPrefix("www.") { first.removeFirst(4) }
            if first.isEmpty { words.removeFirst() } else { words[0] = first }
        }
        return words
    }

    private static func entry(_ row: OpaquePointer) -> HistoryEntry? {
        guard let url = URL(string: text(row, 0)) else { return nil }
        return HistoryEntry(
            url: url,
            title: text(row, 1),
            visitCount: Int(sqlite3_column_int64(row, 2)),
            typedCount: Int(sqlite3_column_int64(row, 3)),
            lastVisitedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 4)),
            key: text(row, 5)
        )
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    // MARK: SQLite

    enum Value {
        case text(String), int(Int64), double(Double), null

        /// A profile ID as the `profile` column holds it.
        static func profile(_ id: UUID) -> Value { .text(id.uuidString) }
    }

    private static func open(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw BrowsingHistoryError.sqlite(code: status, message: message)
        }
        do {
            try migrate(handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        return handle
    }

    private static func migrate(_ db: OpaquePointer) throws {
        // Fails here, not on first write, when the file isn't a database.
        let version = try scalar(db, "PRAGMA user_version")
        guard version <= schemaVersion else { throw BrowsingHistoryError.newerSchema(version) }
        try exec(db, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA secure_delete = ON;")
        if version < 1 {
            try exec(db, """
                BEGIN;
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
                PRAGMA user_version = 1;
                COMMIT;
                """)
        }
        if version < 2 {
            // Profiles: every page so far was visited in the default profile. A page is now unique per
            // profile, which SQLite can only change by copying the table. In one transaction: a failure
            // rolls back to the version-1 table, untouched, and the next launch tries again.
            try exec(db, """
                BEGIN;
                CREATE TABLE places_v2 (
                    id INTEGER PRIMARY KEY,
                    profile TEXT NOT NULL,
                    key TEXT NOT NULL,
                    url TEXT NOT NULL,
                    host TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    search_query TEXT,
                    search_key TEXT,
                    match_text TEXT NOT NULL,
                    visit_count INTEGER NOT NULL DEFAULT 0,
                    typed_count INTEGER NOT NULL DEFAULT 0,
                    last_visit REAL NOT NULL,
                    UNIQUE (profile, key)
                );
                INSERT INTO places_v2 (id, profile, key, url, host, title, search_query, search_key, match_text,
                                       visit_count, typed_count, last_visit)
                    SELECT id, '\(Profile.defaultID.uuidString)', key, url, host, title, search_query, search_key,
                           match_text, visit_count, typed_count, last_visit
                    FROM places;
                DROP TABLE places;
                ALTER TABLE places_v2 RENAME TO places;
                CREATE INDEX places_host ON places (host);
                CREATE INDEX places_last_visit ON places (last_visit);
                PRAGMA user_version = 2;
                COMMIT;
                """)
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw BrowsingHistoryError.sqlite(code: status, message: message)
        }
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if status == SQLITE_OK { status = sqlite3_step(statement) }
        guard status == SQLITE_ROW else {
            throw BrowsingHistoryError.sqlite(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int(statement, 0)
    }

    /// Deletes what `quarantine` set aside next to `fileURL`. Best effort.
    private static func removeQuarantined(beside fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.lastPathComponent + ".corrupt-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Moves a corrupt database (and its WAL and shared-memory files) aside. Best effort.
    private static func quarantine(_ fileURL: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: fileURL.path(percentEncoded: false) + suffix)
            let destination = URL(filePath: fileURL.path(percentEncoded: false) + ".corrupt-\(stamp)" + suffix)
            try? FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// Runs a statement for its effect. Failures are dropped: history is best effort, and a failed
    /// write must never get in the way of browsing.
    private func run(_ sql: String, _ values: [Value] = []) {
        _ = query(sql, values) { _ in () }
    }

    /// Runs a statement for its effect, reporting whether it ran to the end. For writes whose failure
    /// the caller must know about.
    private func change(_ sql: String, _ values: [Value]) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        Self.bind(values, to: statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func query<Row>(_ sql: String, _ values: [Value], _ read: (OpaquePointer) -> Row) -> [Row] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        Self.bind(values, to: statement)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(read(statement)) }
        return rows
    }

    private static func bind(_ values: [Value], to statement: OpaquePointer) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .int(let int): sqlite3_bind_int64(statement, position, int)
            case .double(let double): sqlite3_bind_double(statement, position, double)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
    }

    /// `SQLITE_TRANSIENT`, which the C macro defines as `(sqlite3_destructor_type)-1`.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
