import Foundation
import os
import WebKit

/// Fetches filter lists, converts them, compiles them with WebKit, and hands compiled rule lists
/// to web views. One instance per app. All WebKit calls happen on the main actor.
///
/// Cache layout under `cacheDirectory`:
/// - `lists/<source>.txt`: the raw filter list as last downloaded.
/// - `lists/<source>.meta.json`: `FilterListMetadata` (etag, lastFetched, byteCount, ruleCount, identifiers,
///   converter version, dropped rules).
/// - Compiled lists live in the `WKContentRuleListStore` as
///   `cormorant.<source>.v<converterVersion>.<chunk>.<contentHash>`. Each source compiles to at least
///   two lists (network rules, element hiding) so that network exceptions cannot cancel element hiding.
///
/// Concurrency: at most one refresh runs at a time, and at most one convert-and-compile runs per
/// source; cache loads and refreshes share it instead of compiling the same text twice.
@MainActor
public final class ContentBlockingEngine {
    public enum Status: Sendable, Equatable {
        case idle
        case updating
        case ready(lastUpdated: Date, ruleCount: Int)
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public var preferences: BlockingPreferences

    /// Incremented every time the set of compiled lists for the enabled sources changes (a refresh
    /// or cache load produced different lists, or a refresh after `preferences.enabledSources` changed).
    /// Web views compare it to the version they applied and re-apply when it differs.
    public private(set) var listsVersion: Int = 0

    /// Called on the main actor after `listsVersion` changes.
    public var onListsChanged: (() -> Void)?

    /// After an automatic (background) refresh fails, `ruleLists(for:)` waits this long before
    /// starting another one, so page loads while offline do not hammer the network.
    static let automaticRetryInterval: TimeInterval = 60

    private let cacheDirectory: URL
    private let store: WKContentRuleListStore
    private let session: URLSession
    private let logger = Logger(subsystem: "dev.baldyeagle.cormorant", category: "ContentBlocking")

    private var compiled: [FilterListSource: [WKContentRuleList]] = [:]
    private var cacheLoadAttempted: Set<FilterListSource> = []
    private var cacheLoadTask: Task<Void, Never>?

    private struct InFlightRefresh {
        let serial: Int
        let force: Bool
        let sources: Set<FilterListSource>
        let task: Task<Void, any Error>
    }
    private var refreshInFlight: InFlightRefresh?
    private var refreshSerial = 0
    private var lastRefreshFailure: Date?

    private struct InFlightCompile {
        let token: Int
        /// `textGeneration` when the compile started; the text it reads is at least this new.
        let generation: Int
        let task: Task<[WKContentRuleList], any Error>
    }
    /// The one in-flight convert-and-compile per source.
    private var compileTasks: [FilterListSource: InFlightCompile] = [:]
    private var compileSerial = 0
    /// Bumped when a refresh writes new list text for the source.
    private var textGeneration: [FilterListSource: Int] = [:]
    /// `textGeneration` of the text behind `compiled[source]`.
    private var compiledGeneration: [FilterListSource: Int] = [:]
    /// Identifiers last announced through `listsVersion`.
    private var publishedIdentifiers: [String] = []

    /// Test hook: convert-and-compile runs started per source.
    private(set) var compileRuns: [FilterListSource: Int] = [:]
    /// Test hook: whether a refresh is in flight.
    var isRefreshing: Bool { refreshInFlight != nil }
    /// Test hook: rewrites prepared chunks before compiling (e.g. to inject a rule WebKit rejects).
    var preparedListTransform: ((FilterListCache.PreparedList) -> FilterListCache.PreparedList)?

    /// - Parameters:
    ///   - cacheDirectory: where fetched list text and metadata live (app group or caches).
    ///   - store: compiled-list store; `.default()` in the app, a temp store in tests.
    public init(cacheDirectory: URL, store: WKContentRuleListStore = .default(), preferences: BlockingPreferences = .default) {
        self.preferences = preferences
        self.cacheDirectory = cacheDirectory
        self.store = store
        self.session = .shared
    }

    /// Same as the main initializer with an injectable `URLSession` (tests, custom configuration).
    public init(cacheDirectory: URL, store: WKContentRuleListStore, preferences: BlockingPreferences, session: URLSession) {
        self.preferences = preferences
        self.cacheDirectory = cacheDirectory
        self.store = store
        self.session = session
    }

    /// Compiled lists for `host`, honoring `preferences`. Empty when blocking is off for that host.
    ///
    /// Never touches the network: returns lists from memory, else from the compiled store or cached
    /// text. If nothing is available at all (first launch), returns `[]` at once, sets `status` to
    /// `.updating` and starts a background `refresh()`; when it produces lists, `listsVersion` changes
    /// and `onListsChanged` fires so web views can re-apply. Does not currently throw; `throws` is kept
    /// for source compatibility.
    public func ruleLists(for host: String?) async throws -> [WKContentRuleList] {
        guard preferences.isBlocking(host: host) else { return [] }
        let sources = enabledSources
        guard !sources.isEmpty else { return [] }

        if sources.contains(where: { compiled[$0] == nil && !cacheLoadAttempted.contains($0) }) {
            await loadFromCache()
        }
        let lists = currentLists()
        // Empty because nothing is cached at all (first launch): fetch in the background.
        // Empty because a compile from cached text is still running: just wait for it.
        if lists.isEmpty, compileTasks.isEmpty { startAutomaticRefreshIfNeeded() }
        return lists
    }

    /// Waits for any background cache load or compile started by `ruleLists(for:)` to finish.
    /// `ruleLists` never blocks on compilation; call this when you need the compiled result (tests,
    /// or a caller that prefers a slower first load over an unblocked one).
    public func waitForPendingCompiles() async {
        if let cacheLoadTask { await cacheLoadTask.value }
        while let handle = compileTasks.values.first {
            _ = await handle.task.result
        }
        // Settle status here too: the completion tasks started by `loadSourceFromCache` may not
        // have run yet when this returns.
        if !currentLists().isEmpty, refreshInFlight == nil { updateReadyStatus() }
        publishIfChanged()
    }

    /// Re-fetches lists if older than `maxAge` (default 24h) or `force`, then recompiles.
    /// One list failing does not stop the others; throws only if no list is usable afterwards.
    ///
    /// Only one refresh runs at a time. A non-forced call while one is in flight joins it (unless a
    /// source was enabled since it started). A forced call waits for the in-flight refresh, then runs
    /// its own. Call this after changing `preferences.enabledSources`; `listsVersion` changes if the
    /// resulting set of lists differs.
    public func refresh(force: Bool = false, maxAge: TimeInterval = 24 * 60 * 60) async throws {
        let requestedAfter = refreshSerial
        while let inFlight = refreshInFlight {
            let covers = Set(enabledSources).isSubset(of: inFlight.sources)
            let satisfies = covers && (!force || (inFlight.force && inFlight.serial > requestedAfter))
            if satisfies {
                try await inFlight.task.value
                return
            }
            _ = await inFlight.task.result
        }
        try await startRefresh(force: force, maxAge: maxAge).task.value
    }

    /// Applies the right lists to a web view's user content controller for the page it is about to load.
    public func apply(to controller: WKUserContentController, host: String?) async throws {
        let lists = try await ruleLists(for: host)
        controller.removeAllContentRuleLists()
        for list in lists { controller.add(list) }
    }

    /// Cached metadata for `source` (last fetch date, rule counts), if it has ever been fetched.
    public func metadata(for source: FilterListSource) -> FilterListMetadata? {
        FilterListCache.readMetadata(source, in: cacheDirectory)
    }

    // MARK: - Internals

    private var enabledSources: [FilterListSource] {
        FilterListSource.allCases.filter(preferences.enabledSources.contains)
    }

    private func currentLists() -> [WKContentRuleList] {
        enabledSources.flatMap { compiled[$0] ?? [] }
    }

    /// Bumps `listsVersion` and calls `onListsChanged` if the enabled sources' lists changed.
    private func publishIfChanged() {
        let identifiers = currentLists().compactMap(\.identifier)
        guard identifiers != publishedIdentifiers else { return }
        publishedIdentifiers = identifiers
        listsVersion += 1
        onListsChanged?()
    }

    private func startAutomaticRefreshIfNeeded() {
        guard refreshInFlight == nil else { return }
        if let lastRefreshFailure, Date().timeIntervalSince(lastRefreshFailure) < Self.automaticRetryInterval { return }
        let handle = startRefresh(force: false, maxAge: 24 * 60 * 60)
        Task { [logger] in
            do {
                try await handle.task.value
            } catch {
                logger.notice("Background filter list refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Starts a refresh and records it as in flight. Sets `status` to `.updating` synchronously.
    private func startRefresh(force: Bool, maxAge: TimeInterval) -> InFlightRefresh {
        refreshSerial += 1
        let serial = refreshSerial
        let sources = enabledSources
        status = .updating
        let task = Task {
            defer { if self.refreshInFlight?.serial == serial { self.refreshInFlight = nil } }
            try await self.performRefresh(sources: sources, force: force, maxAge: maxAge)
        }
        let handle = InFlightRefresh(serial: serial, force: force, sources: Set(sources), task: task)
        refreshInFlight = handle
        return handle
    }

    private func performRefresh(sources: [FilterListSource], force: Bool, maxAge: TimeInterval) async throws {
        status = .updating
        // Sources refresh concurrently: fetch and conversion run off the main actor, so they overlap.
        let tasks = sources.map { source in
            (source, Task { try await self.refreshSource(source, force: force, maxAge: maxAge) })
        }
        var failures: [String] = []
        for (source, task) in tasks {
            do {
                try await task.value
            } catch {
                let description = error.localizedDescription
                failures.append(description.hasPrefix(source.displayName) ? description : "\(source.displayName): \(description)")
            }
        }
        guard !currentLists().isEmpty else {
            let reasons = failures.isEmpty ? ["no filter lists enabled"] : failures
            status = .failed(reasons.joined(separator: "; "))
            lastRefreshFailure = Date()
            publishIfChanged()
            throw ContentBlockingError.noRuleListsAvailable(reasons: reasons)
        }
        lastRefreshFailure = nil
        updateReadyStatus()
        publishIfChanged()
    }

    private func refreshSource(_ source: FilterListSource, force: Bool, maxAge: TimeInterval) async throws {
        let outcome = try await FilterListCache.fetch(
            source, cacheDirectory: cacheDirectory, session: session, force: force, maxAge: maxAge)
        if outcome.changed {
            textGeneration[source, default: 0] += 1
        } else if compiled[source] == nil, compileTasks[source] == nil {
            let generation = textGeneration[source, default: 0]
            if let lists = await lookUpRecordedLists(source, allowingOtherConverterVersions: false),
               compiled[source] == nil, compileTasks[source] == nil {
                setCompiled(lists, for: source, generation: generation)
                return
            }
        }
        _ = try await compiledLists(for: source)
    }

    /// Lists compiled from the current cached text: joins the in-flight compile for `source` if it is
    /// new enough, reuses `compiled[source]` if it is, and otherwise starts the one compile.
    private func compiledLists(for source: FilterListSource) async throws -> [WKContentRuleList] {
        let wanted = textGeneration[source, default: 0]
        while true {
            if let inFlight = compileTasks[source] {
                let result = await inFlight.task.result
                if inFlight.generation >= wanted { return try result.get() }
                continue
            }
            if let lists = compiled[source], compiledGeneration[source, default: -1] >= wanted { return lists }
            return try await startCompile(source).task.value
        }
    }

    private func startCompile(_ source: FilterListSource) -> InFlightCompile {
        compileSerial += 1
        let token = compileSerial
        let generation = textGeneration[source, default: 0]
        let task = Task {
            defer { if self.compileTasks[source]?.token == token { self.compileTasks[source] = nil } }
            return try await self.compileCachedText(source, generation: generation)
        }
        let handle = InFlightCompile(token: token, generation: generation, task: task)
        compileTasks[source] = handle
        return handle
    }

    private func setCompiled(_ lists: [WKContentRuleList], for source: FilterListSource, generation: Int) {
        compiled[source] = lists
        compiledGeneration[source] = generation
    }

    /// Converts and compiles `lists/<source>.txt`, reusing compiled chunks whose content is unchanged.
    /// Only ever called through `startCompile`.
    private func compileCachedText(_ source: FilterListSource, generation: Int) async throws -> [WKContentRuleList] {
        compileRuns[source, default: 0] += 1
        var prepared = try await FilterListCache.prepare(source, cacheDirectory: cacheDirectory)
        if let preparedListTransform { prepared = preparedListTransform(prepared) }
        let previous = FilterListCache.readMetadata(source, in: cacheDirectory)
        var lists: [WKContentRuleList] = []
        var dropped: [String: Int] = [:]
        for chunk in prepared.chunks {
            if let existing = await lookUp(chunk.identifier) {
                lists.append(existing)
                if let count = previous?.droppedRulesByIdentifier[chunk.identifier] { dropped[chunk.identifier] = count }
                continue
            }
            let result = try await compileChunk(identifier: chunk.identifier, json: chunk.json, rules: chunk.rules)
            lists.append(result.list)
            if result.droppedRules > 0 { dropped[chunk.identifier] = result.droppedRules }
        }
        setCompiled(lists, for: source, generation: generation)

        let identifiers = prepared.chunks.map(\.identifier)
        var metadata = FilterListCache.readMetadata(source, in: cacheDirectory) ?? FilterListMetadata()
        metadata.byteCount = prepared.byteCount
        metadata.ruleCount = prepared.ruleCount
        metadata.skippedCount = prepared.skippedCount
        metadata.identifiers = identifiers
        metadata.converterVersion = ABPFilterConverter.converterVersion
        metadata.droppedRulesByIdentifier = dropped
        try? FilterListCache.writeMetadata(metadata, for: source, in: cacheDirectory)
        await removeStaleLists(for: source)
        return lists
    }

    /// Fills `compiled` from the store (by recorded identifiers) or, failing that, from cached text.
    /// Never touches the network.
    /// Removes `cormorant-probe.*` lists left behind if the process died mid-bisect.
    private func sweepProbeLists() async {
        guard !probeSweepDone else { return }
        probeSweepDone = true
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers where identifier.hasPrefix(Self.probeIdentifierPrefix) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
            }
        }
    }
    private var probeSweepDone = false

    private func loadFromCache() async {
        await sweepProbeLists()
        if let cacheLoadTask {
            await cacheLoadTask.value
            return
        }
        let task = Task {
            let missing = self.enabledSources.filter { self.compiled[$0] == nil && !self.cacheLoadAttempted.contains($0) }
            let loads = missing.map { source in Task { await self.loadSourceFromCache(source) } }
            for load in loads { await load.value }
            if !self.currentLists().isEmpty, self.status != .updating { self.updateReadyStatus() }
            self.publishIfChanged()
        }
        cacheLoadTask = task
        defer { cacheLoadTask = nil }
        await task.value
    }

    private func loadSourceFromCache(_ source: FilterListSource) async {
        defer { cacheLoadAttempted.insert(source) }
        let generation = textGeneration[source, default: 0]
        let hasText = FilterListCache.hasCachedText(source, in: cacheDirectory)
        // Lists from an older converter are only used when there is no text to rebuild them from.
        if compileTasks[source] == nil,
           let lists = await lookUpRecordedLists(source, allowingOtherConverterVersions: !hasText) {
            if compiled[source] == nil, compileTasks[source] == nil { setCompiled(lists, for: source, generation: generation) }
            return
        }
        guard hasText else { return }
        // Compiling from text takes seconds. The store lookup above is the fast path; when it misses,
        // compile in the background and let `listsVersion` / `onListsChanged` tell web views to re-apply.
        if status == .idle { status = .updating }
        let handle = compileTasks[source] ?? startCompile(source)
        Task { [logger] in
            do {
                _ = try await handle.task.value
                if !self.currentLists().isEmpty, self.status != .updating || self.refreshInFlight == nil {
                    self.updateReadyStatus()
                }
                self.publishIfChanged()
            } catch {
                logger.error("Compiling cached \(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if self.currentLists().isEmpty, self.refreshInFlight == nil {
                    self.status = .failed("\(source.displayName): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Looks up the lists recorded in `source`'s metadata, if they were all compiled by this converter
    /// version (or `allowingOtherConverterVersions`) and are all still in the store.
    private func lookUpRecordedLists(_ source: FilterListSource, allowingOtherConverterVersions: Bool) async -> [WKContentRuleList]? {
        guard let metadata = FilterListCache.readMetadata(source, in: cacheDirectory), !metadata.identifiers.isEmpty,
              allowingOtherConverterVersions || metadata.converterVersion == ABPFilterConverter.converterVersion
        else { return nil }
        return await lookUpAll(metadata.identifiers)
    }

    private func updateReadyStatus() {
        let sources = enabledSources.filter { compiled[$0]?.isEmpty == false }
        let metadata = sources.compactMap { FilterListCache.readMetadata($0, in: cacheDirectory) }
        let lastUpdated = metadata.compactMap(\.lastFetched).max() ?? Date()
        status = .ready(lastUpdated: lastUpdated, ruleCount: metadata.reduce(0) { $0 + $1.ruleCount })
    }

    // MARK: - WebKit store

    private func lookUpAll(_ identifiers: [String]) async -> [WKContentRuleList]? {
        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            guard let list = await lookUp(identifier) else { return nil }
            lists.append(list)
        }
        return lists
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    /// Compiles one chunk. If WebKit rejects it, bisects to find the rules it rejects, drops only
    /// those, and compiles the rest under the same identifier. Throws if the failure is not caused by
    /// individual rules (nothing to drop) or every rule is rejected.
    func compileChunk(identifier: String, json: String, rules: [ContentRule]) async throws
        -> (list: WKContentRuleList, droppedRules: Int) {
        do {
            return (try await compile(identifier: identifier, json: json), 0)
        } catch {
            let kept = await acceptedRules(rules[...])
            let dropped = rules.count - kept.count
            guard dropped > 0, !kept.isEmpty else { throw error }
            logger.warning("WebKit rejected \(dropped) rule(s) in \(identifier, privacy: .public); compiling without them")
            let list = try await compile(identifier: identifier, json: ContentRule.encodedRuleList(kept))
            return (list, dropped)
        }
    }

    /// The rules of `rules` WebKit accepts, in order, found by recursive halving.
    func acceptedRules(_ rules: ArraySlice<ContentRule>) async -> [ContentRule] {
        guard !rules.isEmpty else { return [] }
        if await compiles(rules) { return Array(rules) }
        if rules.count == 1 { return [] }
        let middle = rules.startIndex + rules.count / 2
        let head = await acceptedRules(rules[..<middle])
        let tail = await acceptedRules(rules[middle...])
        return head + tail
    }

    /// A rule WebKit always accepts, prepended to probes so a slice of only exceptions is never empty
    /// of primary rules.
    private static let probeSentinel = ContentRule(
        trigger: .init(urlFilter: "^cormorant-probe:"), action: .block)
    static let probeIdentifierPrefix = "cormorant-probe."

    /// Whether WebKit compiles `rules`. Probe lists are removed from the store right away.
    private func compiles(_ rules: ArraySlice<ContentRule>) async -> Bool {
        let identifier = Self.probeIdentifierPrefix + UUID().uuidString
        let json = ContentRule.encodedRuleList([Self.probeSentinel] + rules)
        guard (try? await compile(identifier: identifier, json: json)) != nil else { return false }
        await removeList(identifier)
        return true
    }

    private func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, any Error>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: ContentBlockingError.compileFailed(
                        identifier: identifier, message: error?.localizedDescription ?? "unknown error"))
                }
            }
        }
    }

    /// Removes `source`'s lists from the store unless they are recorded in its metadata or held in
    /// `compiled`. Both are read after the store listing, so a concurrent update is never deleted.
    private func removeStaleLists(for source: FilterListSource) async {
        let prefix = FilterListCache.identifierPrefix(for: source)
        let available = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            store.getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: identifiers ?? [])
            }
        }
        for identifier in available where identifier.hasPrefix(prefix) {
            let recorded = FilterListCache.readMetadata(source, in: cacheDirectory)?.identifiers ?? []
            let inUse = compiled[source]?.compactMap(\.identifier) ?? []
            guard !recorded.contains(identifier), !inUse.contains(identifier) else { continue }
            await removeList(identifier)
        }
    }

    private func removeList(_ identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }
}
