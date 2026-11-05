import Foundation
import Testing
@testable import CormorantCore

private let day: TimeInterval = 24 * hour

@Suite struct BrowsingHistoryTests {
    // MARK: Keys

    @Test func keysIgnoreSchemeWWWTrailingSlashFragmentAndDefaultPort() {
        let variants = [
            "https://www.example.com/", "http://example.com", "https://EXAMPLE.com:443/#top",
            "https://example.com./", "https://user:secret@example.com/",
        ]
        for variant in variants {
            #expect(BrowsingHistory.key(for: url(variant)) == "example.com", "\(variant)")
        }
        #expect(BrowsingHistory.key(for: url("https://example.com/a/?b=1#c")) == "example.com/a?b=1")
        #expect(BrowsingHistory.key(for: url("http://example.com:8080/x")) == "example.com:8080/x")
        #expect(BrowsingHistory.key(for: url("https://example.com/Path")) == "example.com/Path")
    }

    @Test func nonWebURLsHaveNoKey() {
        for string in ["about:blank", "file:///etc/hosts", "data:text/plain,hi", "mailto:a@b.c", "https:///nohost"] {
            #expect(BrowsingHistory.key(for: url(string)) == nil, "\(string)")
        }
    }

    // MARK: Recording

    @Test func visitsToTheSamePageMerge() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://www.example.com/"), title: "Example", at: t0)
        await store.recordVisit(to: url("http://example.com"), title: "", at: t0 + hour)
        await store.recordVisit(to: url("https://example.com"), typed: true, at: t0 + 2 * hour)
        #expect(await store.pageCount == 1)
        let entry = try #require(await store.pages(matching: "exa", now: t0 + 3 * hour).first)
        #expect(entry.title == "Example")
        #expect(entry.visitCount == 3)
        #expect(entry.typedCount == 1)
        #expect(entry.lastVisitedAt == t0 + 2 * hour)
        // The most recent form of the URL is the one kept (here the typed one).
        #expect(entry.url == url("https://example.com"))
    }

    @Test func nonWebAndOversizedURLsAreNotRecorded() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("about:blank"), at: t0)
        await store.recordVisit(to: url("data:text/html,hello"), at: t0)
        let long = "https://example.com/?q=" + String(repeating: "a", count: BrowsingHistory.maxURLLength)
        await store.recordVisit(to: url(long), at: t0)
        #expect(await store.pageCount == 0)
    }

    @Test func credentialsAreNeverStored() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://alice:hunter2@example.com/inbox"), title: "Inbox", at: t0)
        let entry = try #require(await store.pages(matching: "inbox", now: t0).first)
        #expect(entry.url == url("https://example.com/inbox"))
        #expect(await store.pages(matching: "hunter2", now: t0).isEmpty)
    }

    @Test func titlesUpdate() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://news.example/story"), title: "Old", at: t0)
        await store.updateTitle("Fresh Headline", for: url("https://news.example/story#comments"))
        let entry = try #require(await store.pages(matching: "headline", now: t0).first)
        #expect(entry.title == "Fresh Headline")
        #expect(await store.pages(matching: "old", now: t0).isEmpty)
    }

    @Test func titlesAreSingleLineAndCapped() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        let long = String(repeating: "x", count: 2_000)
        await store.recordVisit(to: url("https://a.example"), title: "  Line one\nline two  ", at: t0)
        await store.recordVisit(to: url("https://b.example"), title: long, at: t0)
        #expect(await store.pages(matching: "a.example", now: t0).first?.title == "Line one line two")
        #expect(await store.pages(matching: "b.example", now: t0).first?.title.count == BrowsingHistory.maxTitleLength)
    }

    // MARK: Matching and ranking

    @Test func everyWordMustMatchTitleOrURL() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://github.com/anthropics/claude-code"), title: "Claude Code", at: t0)
        await store.recordVisit(to: url("https://docs.swift.org/concurrency"), title: "Concurrency", at: t0)
        #expect(await store.pages(matching: "claude github", now: t0).map(\.title) == ["Claude Code"])
        #expect(await store.pages(matching: "CLAUDE  code", now: t0).map(\.title) == ["Claude Code"])
        #expect(await store.pages(matching: "claude swift", now: t0).isEmpty)
        #expect(await store.pages(matching: "https://www.github", now: t0).map(\.title) == ["Claude Code"])
        #expect(await store.pages(matching: "   ", now: t0).isEmpty)
    }

    @Test func nonASCIITitlesMatchCaseInsensitively() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://example.de/strasse"), title: "Über Straßen", at: t0)
        #expect(await store.pages(matching: "über", now: t0).count == 1)
        #expect(await store.pages(matching: "ÜBER", now: t0).count == 1)
    }

    @Test func frecencyPrefersFrequentTypedAndRecentPages() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        let now = t0 + 100 * day
        // Visited a lot, but months ago.
        for i in 0..<5 { await store.recordVisit(to: url("https://old.example/notes"), title: "Notes old", at: t0 + Double(i)) }
        // Visited twice this week.
        for i in 0..<2 { await store.recordVisit(to: url("https://new.example/notes"), title: "Notes new", at: now - day + Double(i)) }
        #expect(await store.pages(matching: "notes", now: now).map(\.title) == ["Notes new", "Notes old"])

        // Typing a page in counts extra: one typed visit beats two plain ones at the same age.
        await store.recordVisit(to: url("https://typed.example/notes"), title: "Notes typed", typed: true, at: now - day)
        #expect(await store.pages(matching: "notes", now: now).first?.title == "Notes typed")
    }

    @Test func hostPrefixMatchesOutrankMatchesElsewhere() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        // Up to four times the frecency, but "git" only appears mid-URL.
        for _ in 0..<3 { await store.recordVisit(to: url("https://blog.example/why-git-rebase"), title: "Rebasing", at: t0) }
        await store.recordVisit(to: url("https://github.com/"), title: "GitHub", at: t0)
        #expect(await store.pages(matching: "git", now: t0).map(\.title) == ["GitHub", "Rebasing"])
    }

    @Test func limitIsRespected() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        for i in 0..<20 { await store.recordVisit(to: url("https://example.com/\(i)"), title: "Page \(i)", at: t0) }
        #expect(await store.pages(matching: "page", limit: 3, now: t0).count == 3)
        #expect(await store.pages(matching: "page", limit: 0, now: t0).isEmpty)
    }

    // MARK: Searches

    @Test func searchPagesSuggestTheirQueryNotThemselves() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=vertical+shower+tile"),
                                title: "vertical shower tile at DuckDuckGo", searchQuery: "vertical shower tile", at: t0)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=Shower+heads"),
                                title: "Shower heads at DuckDuckGo", searchQuery: "Shower heads", at: t0 + hour)
        #expect(await store.pages(matching: "shower", now: t0 + hour).isEmpty)
        // Queries starting with the text come first, then by frecency.
        #expect(await store.searches(matching: "shower", now: t0 + hour) == ["Shower heads", "vertical shower tile"])
        #expect(await store.searches(matching: "tile vertical", now: t0 + hour) == ["vertical shower tile"])
        #expect(await store.searches(matching: "faucet", now: t0 + hour).isEmpty)
    }

    @Test func repeatedSearchesMergeCaseInsensitivelyAcrossEngines() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=swift+testing"), searchQuery: "swift testing", at: t0)
        await store.recordVisit(to: url("https://www.google.com/search?q=Swift%20Testing"), searchQuery: "Swift  Testing", at: t0 + hour)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=swift+concurrency"), searchQuery: "swift concurrency", at: t0 + 2 * hour)
        // Searched twice, so first despite being older; shown as last typed.
        #expect(await store.searches(matching: "swift", now: t0 + 2 * hour) == ["Swift  Testing", "swift concurrency"])
    }

    // MARK: Inline completion

    @Test func completesToTheBestHost() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://www.github.com/a"), at: t0)
        await store.recordVisit(to: url("https://github.com/b"), at: t0)
        await store.recordVisit(to: url("https://gitlab.com/"), at: t0)
        // Two pages on github.com outweigh one on gitlab.com.
        #expect(InlineCompletion(completing: "gi", from: await store.completionHosts(now: t0)) == InlineCompletion(typed: "gi", suffix: "thub.com"))
        #expect(InlineCompletion(completing: "gitl", from: await store.completionHosts(now: t0))?.text == "gitlab.com")
        // Case and a typed `www.` are kept as typed.
        #expect(InlineCompletion(completing: "GitH", from: await store.completionHosts(now: t0))?.text == "GitHub.com")
        #expect(InlineCompletion(completing: "www.gith", from: await store.completionHosts(now: t0))?.text == "www.github.com")
    }

    @Test func doesNotCompleteWholeHostsPathsOrPhrases() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://github.com/"), at: t0)
        for typed in ["", "github.com", "github.com/", "gi thub", "https://gi", "www.", "user@gi", "github.com:443"] {
            #expect(InlineCompletion(completing: typed, from: await store.completionHosts(now: t0)) == nil, "\(typed)")
        }
    }

    @Test func completesToTheVisitedPort() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("http://localhost:3000/app"), at: t0)
        await store.recordVisit(to: url("https://example.com:443/?q=1"), at: t0)
        let hosts = await store.completionHosts(now: t0)
        #expect(InlineCompletion(completing: "loc", from: hosts)?.text == "localhost:3000")
        #expect(InlineCompletion(completing: "localhost", from: hosts)?.text == "localhost:3000")
        // A default port isn't part of the site; a query with no path doesn't leak into it.
        #expect(InlineCompletion(completing: "exa", from: hosts)?.text == "example.com")
    }

    @Test func searchPagesDoNotDriveCompletion() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://duckduckgo.com/?q=a"), searchQuery: "a", at: t0)
        #expect(InlineCompletion(completing: "duck", from: await store.completionHosts(now: t0)) == nil)
    }

    // MARK: Removal and pruning

    @Test func removal() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://a.example"), at: t0)
        await store.recordVisit(to: url("https://b.example"), at: t0 + day)
        await store.recordVisit(to: url("https://c.example"), at: t0 + 2 * day)
        await store.removePages(visitedSince: t0 + day)
        #expect(await store.pageCount == 1)
        await store.removePage(url("http://www.a.example/"))
        #expect(await store.pageCount == 0)
        await store.recordVisit(to: url("https://d.example"), at: t0)
        await store.removeAll()
        #expect(await store.pageCount == 0)
    }

    @Test func pruneKeepsTheMostRecentlyVisited() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        for i in 0..<10 { await store.recordVisit(to: url("https://example.com/\(i)"), title: "Page \(i)", at: t0 + Double(i)) }
        await store.prune(capacity: 3)
        #expect(await store.pageCount == 3)
        #expect(Set(await store.pages(matching: "page", now: t0 + 10).map(\.title)) == ["Page 7", "Page 8", "Page 9"])
    }

    // MARK: Files

    @Test func persistsAcrossOpens() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "nested/history.sqlite")
        do {
            let store = try BrowsingHistory(fileURL: file)
            await store.recordVisit(to: url("https://example.com"), title: "Example", at: t0)
        }
        let reopened = try BrowsingHistory(fileURL: file)
        #expect(await reopened.pages(matching: "example", now: t0).map(\.title) == ["Example"])
    }

    /// Clearing any span of history deletes them: they may hold pages from it.
    @Test(arguments: [false, true]) func clearingDeletesSetAsideCopies(all: Bool) async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.sqlite")
        try Data(repeating: 0x42, count: 8_192).write(to: file)
        try Data("unrelated".utf8).write(to: dir.appending(path: "other.sqlite.corrupt-1"))
        let store = try BrowsingHistory(fileURL: file)
        if all { await store.removeAll() } else { await store.removePages(visitedSince: t0) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(!names.contains { $0.hasPrefix("history.sqlite.corrupt-") })
        #expect(names.contains("other.sqlite.corrupt-1"))
    }

    @Test func sitesKeepOneURLPerHostAndScheme() async throws {
        let store = try BrowsingHistory(fileURL: nil)
        await store.recordVisit(to: url("https://a.example/1"), at: t0)
        await store.recordVisit(to: url("https://a.example/2"), at: t0)
        await store.recordVisit(to: url("http://a.example/3"), at: t0)
        await store.recordVisit(to: url("https://b.example/"), at: t0)
        let sites = await store.sites()
        #expect(sites.count == 3)
        #expect(Set(sites.map { "\($0.scheme!)://\($0.host()!)" }) == ["https://a.example", "http://a.example", "https://b.example"])
    }

    @Test func corruptFileIsSetAsideAndReplaced() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.sqlite")
        try Data(repeating: 0x42, count: 8_192).write(to: file)
        let store = try BrowsingHistory(fileURL: file)
        await store.recordVisit(to: url("https://example.com"), at: t0)
        #expect(await store.pageCount == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("history.sqlite.corrupt-") })
    }
}

@Suite struct SearchEngineQueryTests {
    @Test func readsQueriesFromResultsPages() {
        #expect(SearchEngine.duckDuckGo.query(in: url("https://duckduckgo.com/?q=vertical+shower+tile&ia=web")) == "vertical shower tile")
        #expect(SearchEngine.google.query(in: url("https://www.google.com/search?q=a%2Bb+c&client=safari")) == "a+b c")
        #expect(SearchEngine.google.query(in: url("https://google.com/search?q=no+www")) == "no www")
        #expect(SearchEngine.kagi.query(in: url("https://kagi.com/search?q=%E2%9C%93")) == "✓")
        #expect(SearchEngine.startpage.query(in: url("https://www.startpage.com/do/search?q=x")) == "x")
    }

    @Test func otherPagesAreNotResults() {
        #expect(SearchEngine.duckDuckGo.query(in: url("https://duckduckgo.com/")) == nil)
        #expect(SearchEngine.duckDuckGo.query(in: url("https://duckduckgo.com/?q=+")) == nil)
        #expect(SearchEngine.google.query(in: url("https://www.google.com/maps?q=coffee")) == nil)
        #expect(SearchEngine.google.query(in: url("https://evil.example/search?q=x")) == nil)
        #expect(SearchEngine.google.query(in: url("ftp://www.google.com/search?q=x")) == nil)
        let pathTemplate = SearchEngine(id: "p", name: "P", queryTemplate: "https://p.example/s/{query}")
        #expect(pathTemplate.query(in: url("https://p.example/s/hello")) == nil)
    }
}
