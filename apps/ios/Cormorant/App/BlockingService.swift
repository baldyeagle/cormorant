import CormorantBlocking
import Foundation
import Observation
import OSLog
import WebKit

/// App-wide owner of the content-blocking engine. Persists preferences and mirrors the
/// engine's status for SwiftUI (the engine itself isn't observable).
@MainActor
@Observable
final class BlockingService {
    private static let preferencesKey = "blockingPreferences"

    private(set) var status: ContentBlockingEngine.Status = .idle
    private(set) var preferences: BlockingPreferences

    /// Called on the main actor after the engine's compiled list set changes.
    @ObservationIgnored var onListsChanged: (() -> Void)?

    @ObservationIgnored private let engine: ContentBlockingEngine
    /// The lists last installed for a blocking host, kept so a web view WebKit creates synchronously
    /// (`window.open`) can get rules before its first load.
    @ObservationIgnored private var lastAppliedLists: [WKContentRuleList] = []
    @ObservationIgnored private var lastAppliedVersion = 0
    @ObservationIgnored private let usesFilterLists: Bool

    /// - Parameter usesFilterLists: false for UI tests: nothing is fetched, compiled or installed, so
    ///   no launch waits on the network or competes with a multi-second compile, and pages load unblocked.
    init(usesFilterLists: Bool = true) {
        self.usesFilterLists = usesFilterLists
        let preferences = AppGroupStorage.load(BlockingPreferences.self, key: Self.preferencesKey) ?? .default
        let cacheDirectory = AppGroupStorage.blockingCacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        engine = ContentBlockingEngine(cacheDirectory: cacheDirectory, store: .default(), preferences: preferences)
        self.preferences = preferences
        engine.onListsChanged = { [weak self] in self?.listsDidChange() }
    }

    /// Bumped by the engine whenever the compiled list set changes.
    var listsVersion: Int { engine.listsVersion }

    func isBlocking(host: String?) -> Bool {
        preferences.isBlocking(host: host)
    }

    /// Re-fetches and recompiles lists. Non-forced calls respect the engine's max age.
    /// Errors end up in `status`.
    func refresh(force: Bool = false) async {
        guard usesFilterLists else { return }
        status = .updating
        do {
            try await engine.refresh(force: force)
            syncStatus()
        } catch {
            Logger.app.error("Filter list refresh failed: \(error.localizedDescription, privacy: .public)")
            syncStatus()
            if case .failed = status {} else { status = .failed(error.localizedDescription) }
        }
    }

    /// Installs the right rule lists for `host`. Returns the lists version that was applied, or nil
    /// when the lists couldn't be loaded (the controller is left as it was; the page loads unblocked).
    func apply(to controller: WKUserContentController, host: String?) async -> Int? {
        // Not even the engine's cached lists: with none cached it would start a refresh itself.
        guard usesFilterLists else { return engine.listsVersion }
        do {
            let lists = try await engine.ruleLists(for: host)
            let version = engine.listsVersion
            controller.removeAllContentRuleLists()
            for list in lists { controller.add(list) }
            if preferences.isBlocking(host: host) {
                lastAppliedLists = lists
                lastAppliedVersion = version
            }
            syncStatus()
            return version
        } catch {
            Logger.app.error("Applying blocking rules failed: \(error.localizedDescription, privacy: .public)")
            syncStatus()
            return nil
        }
    }

    /// Already-compiled lists for `host`, available synchronously, and the version they came from.
    func cachedLists(for host: String?) -> (lists: [WKContentRuleList], version: Int) {
        (preferences.isBlocking(host: host) ? lastAppliedLists : [], lastAppliedVersion)
    }

    func update(_ change: (inout BlockingPreferences) -> Void) {
        change(&preferences)
        engine.preferences = preferences
        AppGroupStorage.save(preferences, key: Self.preferencesKey)
    }

    func syncStatus() {
        if status != engine.status { status = engine.status }
    }

    private func listsDidChange() {
        syncStatus()
        onListsChanged?()
    }
}
