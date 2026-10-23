import Foundation
import Synchronization
import Testing
import WebKit
@testable import CormorantBlocking

@Suite("ContentBlockingEngine", .timeLimit(.minutes(1)))
@MainActor
struct ContentBlockingEngineTests {
    private let easyListOnly = BlockingPreferences(enabledSources: [.easyList])

    /// A cache directory with the bundled excerpt written as `lists/easyList.txt` (no metadata yet).
    /// Callers remove it with `TestResources.removeDirectory` in a `defer`.
    private func seededCache(sources: [FilterListSource] = [.easyList]) throws -> URL {
        let cache = try TestResources.temporaryDirectory("cache")
        let lists = cache.appendingPathComponent("lists", isDirectory: true)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        for source in sources {
            try TestResources.easyListExcerpt().write(
                to: lists.appendingPathComponent("\(source.rawValue).txt"), atomically: true, encoding: .utf8)
        }
        return cache
    }

    /// Serves the excerpt (with an ETag, answering 304 to a matching If-None-Match) for `sources`;
    /// every other URL times out. `requests` counts requests per source.
    private func servingSession(_ sources: Set<FilterListSource>, requests: RequestCounter) throws -> URLSession {
        let excerpt = try TestResources.easyListExcerpt()
        return StubURLProtocol.session { request in
            guard let source = FilterListSource.allCases.first(where: { $0.url == request.url }), sources.contains(source) else {
                return .failure(URLError(.timedOut))
            }
            requests.record(source)
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return .success(.init(status: 304)) }
            return .success(.init(status: 200, headers: ["ETag": "\"v1\""], body: Data(excerpt.utf8)))
        }
    }

    @Test func compilesFromCachedTextWithoutNetwork() async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        _ = try await engine.ruleLists(for: "example.com")
        await engine.waitForPendingCompiles()
        let lists = try await engine.ruleLists(for: "example.com")
        #expect(lists.count == 2)  // network + cosmetic
        #expect(lists.allSatisfy { $0.identifier.hasPrefix("cormorant.easyList.v\(ABPFilterConverter.converterVersion).") })
        guard case .ready(_, let ruleCount) = engine.status else {
            Issue.record("status should be ready, was \(engine.status)")
            return
        }
        #expect(ruleCount > 1_000)

        let metadata = try #require(engine.metadata(for: .easyList))
        #expect(metadata.identifiers == lists.map(\.identifier))
        #expect(metadata.ruleCount == ruleCount)
        #expect(metadata.converterVersion == ABPFilterConverter.converterVersion)
        #expect(metadata.droppedRuleCount == 0)
        #expect(Set(await compiler.availableIdentifiers()) == Set(metadata.identifiers))
        #expect(engine.compileRuns == [.easyList: 1])

        // Second call is served from memory.
        let again = try await engine.ruleLists(for: nil)
        #expect(again.map(\.identifier) == lists.map(\.identifier))
        #expect(engine.compileRuns == [.easyList: 1])
    }

    @Test func returnsNothingForDisabledHostsOrWhenOff() async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        var preferences = easyListOnly
        preferences.setBlocking(false, host: "www.example.com")
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: preferences,
                                           session: StubURLProtocol.session())
        #expect(try await engine.ruleLists(for: "example.com").isEmpty)
        #expect(try await engine.ruleLists(for: "EXAMPLE.com").isEmpty)
        _ = try await engine.ruleLists(for: "other.com")
        await engine.waitForPendingCompiles()
        #expect(try await !engine.ruleLists(for: "other.com").isEmpty)

        engine.preferences.isEnabled = false
        #expect(try await engine.ruleLists(for: "other.com").isEmpty)
    }

    @Test func secondLaunchLooksUpCompiledListsInsteadOfRecompiling() async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let first = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                          session: StubURLProtocol.session())
        let identifiers = try await first.ruleLists(for: nil).map(\.identifier)

        // Remove the cached text: a relaunch must still work from the compiled store via metadata.
        try FileManager.default.removeItem(at: cache.appendingPathComponent("lists/easyList.txt"))
        let second = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        #expect(try await second.ruleLists(for: "example.com").map(\.identifier) == identifiers)
        #expect(second.compileRuns.isEmpty)
    }

    /// `ruleLists(for:)` never waits on the network: offline with nothing cached it returns `[]` at
    /// once and refreshes in the background.
    @Test func offlineFirstLaunchReturnsNothingAndRefreshesInBackground() async throws {
        let cache = try TestResources.temporaryDirectory("empty")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store,
                                           preferences: .default, session: StubURLProtocol.session())
        var changes = 0
        engine.onListsChanged = { changes += 1 }

        #expect(try await engine.ruleLists(for: "example.com").isEmpty)
        #expect(engine.status == .updating)
        #expect(engine.isRefreshing)

        // A non-forced refresh joins the background one and sees its failure.
        await #expect {
            try await engine.refresh()
        } throws: { error in
            guard case ContentBlockingError.noRuleListsAvailable(let reasons) = error else { return false }
            return reasons.count == FilterListSource.defaultSet.count
        }
        guard case .failed = engine.status else {
            Issue.record("status should be failed, was \(engine.status)")
            return
        }
        #expect(engine.listsVersion == 0)
        #expect(changes == 0)

        // Within the retry interval, page loads do not start another refresh.
        #expect(try await engine.ruleLists(for: "example.com").isEmpty)
        #expect(!engine.isRefreshing)

        // Blocking off for a host never refreshes either.
        engine.preferences.setBlocking(false, host: "example.com")
        #expect(try await engine.ruleLists(for: "example.com").isEmpty)
    }

    @Test func backgroundRefreshPublishesListsWhenItSucceeds() async throws {
        let cache = try TestResources.temporaryDirectory("background")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let requests = RequestCounter()
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: try servingSession([.easyList], requests: requests))
        var changes: [Int] = []
        engine.onListsChanged = { [unowned engine] in changes.append(engine.listsVersion) }

        #expect(try await engine.ruleLists(for: nil).isEmpty)
        #expect(engine.status == .updating)
        try await engine.refresh()  // joins the background refresh

        #expect(changes == [1])
        #expect(engine.listsVersion == 1)
        let lists = try await engine.ruleLists(for: nil)
        #expect(lists.map(\.identifier) == (try #require(engine.metadata(for: .easyList))).identifiers)
        #expect(requests.counts == [.easyList: 1])
        #expect(changes == [1])
        guard case .ready = engine.status else {
            Issue.record("status should be ready, was \(engine.status)")
            return
        }
    }

    @Test func refreshUsesETagsAndRemovesStaleLists() async throws {
        let excerpt = try TestResources.easyListExcerpt()
        let served = Mutex((body: excerpt, etag: "\"v1\"", requests: 0, conditional: 0))
        let session = StubURLProtocol.session { request in
            served.withLock { state in
                state.requests += 1
                if request.value(forHTTPHeaderField: "If-None-Match") == state.etag {
                    state.conditional += 1
                    return .success(.init(status: 304))
                }
                return .success(.init(status: 200, headers: ["ETag": state.etag], body: Data(state.body.utf8)))
            }
        }
        let cache = try TestResources.temporaryDirectory("etag")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly, session: session)
        var changes = 0
        engine.onListsChanged = { changes += 1 }

        try await engine.refresh()
        let v1 = try #require(engine.metadata(for: .easyList))
        #expect(v1.etag == "\"v1\"")
        #expect(v1.lastFetched != nil)
        #expect(v1.byteCount == excerpt.utf8.count)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("lists/easyList.txt").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("lists/easyList.meta.json").path))
        #expect(engine.listsVersion == 1 && changes == 1)

        // Fresh cache: no request at all.
        try await engine.refresh()
        #expect(served.withLock { $0.requests } == 1)

        // Forced: conditional request, 304, same lists, no change announced.
        try await engine.refresh(force: true)
        #expect(served.withLock { $0.conditional } == 1)
        #expect(engine.metadata(for: .easyList)?.identifiers == v1.identifiers)
        #expect(engine.listsVersion == 1 && changes == 1)

        // New content: recompiled, old identifiers removed from the store.
        served.withLock { $0 = (body: excerpt + "\n||new-tracker.example^\n", etag: "\"v2\"", requests: $0.requests, conditional: $0.conditional) }
        try await engine.refresh(force: true)
        let v2 = try #require(engine.metadata(for: .easyList))
        #expect(v2.etag == "\"v2\"")
        #expect(v2.identifiers != v1.identifiers)
        #expect(Set(await compiler.availableIdentifiers()) == Set(v2.identifiers))
        #expect(try await engine.ruleLists(for: nil).map(\.identifier) == v2.identifiers)
        #expect(engine.listsVersion == 2 && changes == 2)
        #expect(engine.compileRuns == [.easyList: 2])
    }

    @Test func changingEnabledSourcesChangesListsVersionOnRefresh() async throws {
        let cache = try TestResources.temporaryDirectory("sources")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let requests = RequestCounter()
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: try servingSession([.easyList, .easyPrivacy], requests: requests))
        var changes = 0
        engine.onListsChanged = { changes += 1 }

        try await engine.refresh()
        #expect(engine.listsVersion == 1)

        engine.preferences.enabledSources = [.easyList, .easyPrivacy]
        try await engine.refresh()
        #expect(engine.listsVersion == 2)
        #expect(try await engine.ruleLists(for: nil).count == 4)

        engine.preferences.enabledSources = [.easyList]
        try await engine.refresh()
        #expect(engine.listsVersion == 3)
        #expect(try await engine.ruleLists(for: nil).count == 2)

        try await engine.refresh()
        #expect(engine.listsVersion == 3)
        #expect(changes == 3)
        #expect(requests.counts == [.easyList: 1, .easyPrivacy: 1])
    }

    @Test func forcedRefreshWhileOneIsInFlightRunsAgainAfterIt() async throws {
        let cache = try TestResources.temporaryDirectory("force")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let requests = RequestCounter()
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: try servingSession([.easyList], requests: requests))

        let first = Task { try await engine.refresh(force: true) }
        while !engine.isRefreshing { await Task.yield() }
        try await engine.refresh(force: true)  // waits for `first`, then fetches again
        #expect(requests.counts[.easyList] == 2)
        try await first.value
        #expect(!engine.isRefreshing)

        // A non-forced refresh joins the in-flight one instead.
        let third = Task { try await engine.refresh(force: true) }
        while !engine.isRefreshing { await Task.yield() }
        try await engine.refresh()
        try await third.value
        #expect(requests.counts[.easyList] == 3)
        #expect(engine.compileRuns == [.easyList: 1])
    }

    /// Reviewer race: a refresh and a cache load for the same source must share one compile, and the
    /// metadata they leave behind must only name lists that exist.
    @Test(arguments: [false, true])
    func concurrentRefreshAndCacheLoadCompileOnce(refreshFirst: Bool) async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        // Fresh but stale metadata: names a list that is not in the store.
        let staleID = "cormorant.easyList.v\(ABPFilterConverter.converterVersion).0.0000000000000000"
        var stale = FilterListMetadata(lastFetched: Date(), byteCount: 1, ruleCount: 1, identifiers: [staleID])
        stale.converterVersion = ABPFilterConverter.converterVersion
        try FilterListCache.writeMetadata(stale, for: .easyList, in: cache)
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())

        if refreshFirst {
            async let refreshed: Void = engine.refresh()
            async let loaded = engine.ruleLists(for: nil)
            try await refreshed
            _ = try await loaded
        } else {
            async let loaded = engine.ruleLists(for: nil)
            async let refreshed: Void = engine.refresh()
            _ = try await loaded
            try await refreshed
        }
        await engine.waitForPendingCompiles()
        let lists = try await engine.ruleLists(for: nil)

        #expect(engine.compileRuns == [.easyList: 1])
        let metadata = try #require(engine.metadata(for: .easyList))
        let available = Set(await compiler.availableIdentifiers())
        #expect(!metadata.identifiers.isEmpty)
        #expect(!metadata.identifiers.contains(staleID))
        #expect(Set(metadata.identifiers).isSubset(of: available))
        #expect(available == Set(metadata.identifiers))
        #expect(lists.map(\.identifier) == metadata.identifiers)
        #expect(try await engine.ruleLists(for: nil).map(\.identifier) == metadata.identifiers)
    }

    @Test func listsFromAnOlderConverterAreRecompiled() async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        // Lists compiled by converter v1 (identifier scheme without a version) for the same text.
        let oldID = "cormorant.easyList.0.0123456789abcdef"
        _ = try await compiler.compile([.blockRule("old-converter")], identifier: oldID)
        try FilterListCache.writeMetadata(FilterListMetadata(lastFetched: Date(), ruleCount: 1, identifiers: [oldID]),
                                          for: .easyList, in: cache)

        // Cache-load path.
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        _ = try await engine.ruleLists(for: nil)
        await engine.waitForPendingCompiles()
        let lists = try await engine.ruleLists(for: nil)
        #expect(engine.compileRuns == [.easyList: 1])
        #expect(lists.count == 2)
        #expect(lists.allSatisfy { $0.identifier.contains(".v\(ABPFilterConverter.converterVersion).") })
        #expect(engine.metadata(for: .easyList)?.converterVersion == ABPFilterConverter.converterVersion)
        #expect(!(await compiler.availableIdentifiers()).contains(oldID))

        // Refresh path: unchanged text (fresh, no fetch) but metadata from converter version 1.
        var outdated = try #require(engine.metadata(for: .easyList))
        outdated.converterVersion = 1
        try FilterListCache.writeMetadata(outdated, for: .easyList, in: cache)
        let relaunched = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                               session: StubURLProtocol.session())
        try await relaunched.refresh()
        #expect(relaunched.compileRuns == [.easyList: 1])
        #expect(relaunched.metadata(for: .easyList)?.converterVersion == ABPFilterConverter.converterVersion)
    }

    @Test func outdatedListsAreStillUsedWhenThereIsNoTextToRebuildFrom() async throws {
        let cache = try TestResources.temporaryDirectory("outdated")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let oldID = "cormorant.easyList.0.0123456789abcdef"
        _ = try await compiler.compile([.blockRule("old-converter")], identifier: oldID)
        try FilterListCache.writeMetadata(FilterListMetadata(lastFetched: Date(), identifiers: [oldID]), for: .easyList, in: cache)
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        #expect(try await engine.ruleLists(for: nil).map(\.identifier) == [oldID])
        #expect(engine.compileRuns.isEmpty)
    }

    @Test func oneFailingListDoesNotBlockTheOthers() async throws {
        let excerpt = try TestResources.easyListExcerpt()
        let session = StubURLProtocol.session { request in
            if request.url == FilterListSource.easyList.url {
                return .success(.init(status: 200, body: Data(excerpt.utf8)))
            }
            if request.url == FilterListSource.easyPrivacy.url {
                return .success(.init(status: 200, body: Data("<html>captive portal</html>".utf8)))
            }
            return .failure(URLError(.timedOut))
        }
        let cache = try TestResources.temporaryDirectory("partial")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: .default, session: session)
        try await engine.refresh()
        let lists = try await engine.ruleLists(for: nil)
        #expect(!lists.isEmpty)
        #expect(lists.allSatisfy { $0.identifier.hasPrefix("cormorant.easyList.") })
        #expect(engine.metadata(for: .easyPrivacy) == nil)
        guard case .ready = engine.status else {
            Issue.record("status should be ready, was \(engine.status)")
            return
        }
    }

    // MARK: Rules WebKit rejects

    @Test func bisectDropsExactlyTheRuleWebKitRejects() async throws {
        let cache = try TestResources.temporaryDirectory("bisect")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        var rules = (0..<40).map { ContentRule.blockRule(#"^https?://good\#($0)\.example/"#) }
        let bad = ContentRule.blockRule("ads{2}")  // counted repetition: WebKit rejects it
        rules.insert(bad, at: 23)
        rules.append(.exceptionRule(#"^https?://good3\.example/ok"#))
        // Sanity: the list as a whole is rejected.
        await #expect(throws: (any Error).self) { try await compiler.compile(rules) }

        var expected = rules
        expected.remove(at: 23)
        #expect(await engine.acceptedRules(rules[...]) == expected)

        let identifier = "cormorant.easyList.v\(ABPFilterConverter.converterVersion).0.test"
        let result = try await engine.compileChunk(identifier: identifier, json: ContentRule.encodedRuleList(rules), rules: rules)
        #expect(result.droppedRules == 1)
        #expect(result.list.identifier == identifier)
        // Probe lists are not left behind.
        #expect(await compiler.availableIdentifiers() == [identifier])
    }

    @Test func compileChunkStillThrowsWhenNoRuleIsToBlame() async throws {
        let cache = try TestResources.temporaryDirectory("bisect-fail")
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        await #expect(throws: (any Error).self) {
            _ = try await engine.compileChunk(identifier: "cormorant.easyList.empty", json: "[]", rules: [])
        }
        let allBad = [ContentRule.blockRule("a{2}"), .blockRule("(a|b)")]
        await #expect(throws: (any Error).self) {
            _ = try await engine.compileChunk(identifier: "cormorant.easyList.bad", json: ContentRule.encodedRuleList(allBad), rules: allBad)
        }
        #expect(await compiler.availableIdentifiers().isEmpty)
    }

    @Test func droppedRulesAreRecordedInMetadata() async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        // Inject a rule the converter would never emit into the first (network) chunk.
        engine.preparedListTransform = { prepared in
            var prepared = prepared
            prepared.chunks[0].rules.insert(.blockRule("ads{2}"), at: 0)
            prepared.chunks[0].json = ContentRule.encodedRuleList(prepared.chunks[0].rules)
            return prepared
        }
        _ = try await engine.ruleLists(for: nil)
        await engine.waitForPendingCompiles()
        let lists = try await engine.ruleLists(for: nil)
        #expect(lists.count == 2)
        let metadata = try #require(engine.metadata(for: .easyList))
        #expect(metadata.droppedRuleCount == 1)
        #expect(metadata.droppedRulesByIdentifier == [metadata.identifiers[0]: 1])
        guard case .ready = engine.status else {
            Issue.record("status should be ready, was \(engine.status)")
            return
        }
    }

    @Test func applyInstallsListsThatHideElementsInAWebView() async throws {
        let cache = try seededCache()
        defer { TestResources.removeDirectory(cache) }
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        let engine = ContentBlockingEngine(cacheDirectory: cache, store: compiler.store, preferences: easyListOnly,
                                           session: StubURLProtocol.session())
        // A simple generic class selector from the excerpt.
        let conversion = ABPFilterConverter.convertPartitioned(try TestResources.easyListExcerpt())
        let selector = try #require(conversion.cosmetic.first { rule in
            guard let selector = rule.action.selector, rule.trigger.ifDomain == nil, rule.trigger.unlessDomain == nil else { return false }
            return selector.hasPrefix(".") && selector.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }?.action.selector)

        let configuration = WKWebViewConfiguration()
        _ = try await engine.ruleLists(for: "example.org")
        await engine.waitForPendingCompiles()
        try await engine.apply(to: configuration.userContentController, host: "example.org")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        // Standards mode matters: in quirks mode WebKit's content-blocker stylesheet fails to match
        // class selectors containing uppercase letters (observed on macOS 27).
        let html = "<!DOCTYPE html><html><body><div id=t class=\"\(selector.dropFirst())\">ad</div><div id=c>content</div></body></html>"
        try await NavigationWaiter.load(html, baseURL: URL(string: "https://example.org/")!, in: webView)
        #expect(try await webView.evaluate("getComputedStyle(document.getElementById('t')).display") == "none")
        #expect(try await webView.evaluate("getComputedStyle(document.getElementById('c')).display") == "block")

        // Turning blocking off for the host and re-applying removes the lists.
        engine.preferences.setBlocking(false, host: "example.org")
        try await engine.apply(to: configuration.userContentController, host: "example.org")
        try await NavigationWaiter.load(html, baseURL: URL(string: "https://example.org/")!, in: webView)
        #expect(try await webView.evaluate("getComputedStyle(document.getElementById('t')).display") == "block")
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    static func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        webView.navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

extension WKWebView {
    @MainActor
    fileprivate func evaluate(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
            evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String)
                }
            }
        }
    }
}
