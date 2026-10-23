import CormorantBlocking
import CormorantCore
import Observation
import OSLog
import UIKit
import WebKit

/// Owns the persisted tab state and the live web views behind it.
@MainActor
@Observable
final class BrowserStore {
    /// Saved tabs couldn't be loaded. Until the user chooses Start Fresh the app runs on an
    /// in-memory state and never saves, so the unreadable file is not overwritten.
    struct LoadFailure: Equatable {
        /// File name of the copy kept aside, if one could be made.
        let keptCopyName: String?
    }

    /// Fixed for build one; a setting later.
    static let archivePolicy = ArchivePolicy.oneDay
    /// Web views are kept for this many most-recently-viewed tabs; older ones are rebuilt on demand.
    static let liveWebViewLimit = 10
    private static let warnedStorageFallbackKey = "warnedAppGroupUnavailable"

    private(set) var state = BrowserState.empty
    private(set) var isLoaded = false
    private(set) var loadFailure: LoadFailure?
    /// The app group was unavailable and tabs are stored in Application Support instead. Shown once.
    private(set) var showsStorageFallbackWarning = false
    private(set) var activeSession: TabSession?
    private(set) var snapshots: [UUID: UIImage] = [:]
    /// Bumped to ask the browser screen to focus the address field.
    private(set) var addressFocusRequest = 0

    let blocking: BlockingService
    let settings: AppSettings

    @ObservationIgnored private let stateStore: any BrowserStateStore
    @ObservationIgnored private let inbox: SharedInbox?
    @ObservationIgnored private var sessions: [UUID: TabSession] = [:]
    @ObservationIgnored private var recentTabIDs: [UUID] = []
    /// Back/forward history of tabs whose web views were evicted, restored when they're rebuilt.
    @ObservationIgnored private var interactionStates: [UUID: Any] = [:]
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var sceneIsActive = true
    @ObservationIgnored private var debouncedSave: Task<Void, Never>?
    /// Tail of the save chain. Every save waits for the one before it, so writes land in order.
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var saveSequence = 0
    @ObservationIgnored private var lastWrittenSequence = 0

    init(
        stateStore: (any BrowserStateStore)? = nil,
        blocking: BlockingService = BlockingService(),
        settings: AppSettings = AppSettings()
    ) {
        var usesFallbackStorage = false
        if let stateStore {
            self.stateStore = stateStore
        } else if let groupStore = JSONBrowserStateStore(appGroup: AppGroup.identifier) {
            self.stateStore = groupStore
        } else {
            let fallback = URL.applicationSupportDirectory.appending(path: "browser-state.json")
            Logger.app.fault("""
                App group \(AppGroup.identifier, privacy: .public) is unavailable (check the entitlement). \
                Storing tabs at \(fallback.path, privacy: .public); the share extension can't reach the app.
                """)
            self.stateStore = JSONBrowserStateStore(fileURL: fallback)
            usesFallbackStorage = true
        }
        inbox = SharedInbox(appGroup: AppGroup.identifier)
        if inbox == nil {
            Logger.app.fault("App group unavailable: shared links can't be received.")
        }
        self.blocking = blocking
        self.settings = settings
        showsStorageFallbackWarning = usesFallbackStorage
            && !UserDefaults.standard.bool(forKey: Self.warnedStorageFallbackKey)
        blocking.onListsChanged = { [weak self] in self?.reapplyBlockingEverywhere() }
    }

    /// Tabs in the active Space, most recently viewed first.
    var tabs: [Tab] { state.activeSpaceTabs }

    var activeTab: Tab? {
        guard let id = state.activeTabID else { return nil }
        return state.tabs.first { $0.id == id }
    }

    // MARK: Lifecycle

    func launch() async {
        guard !isLoaded else { return }
        do {
            state = try await stateStore.load()
        } catch BrowserStateStoreError.unreadable(let quarantinedTo, let underlying) {
            Logger.app.fault("Saved tabs unreadable (\(underlying, privacy: .public)); moved to \(quarantinedTo?.path ?? "nowhere", privacy: .public). Saving is off until Start Fresh.")
            state = .empty
            loadFailure = LoadFailure(keptCopyName: quarantinedTo?.lastPathComponent)
        } catch {
            Logger.app.fault("Loading saved tabs failed: \(error.localizedDescription, privacy: .public). Saving is off until Start Fresh.")
            state = .empty
            loadFailure = LoadFailure(keptCopyName: await keepCopyOfStateFile())
        }
        isLoaded = true
        Task { await blocking.refresh() }
        didBecomeActive()
    }

    /// The user accepted losing the unreadable tabs; saving resumes with the current state.
    func startFresh() {
        loadFailure = nil
        saveNow()
    }

    func dismissStorageFallbackWarning() {
        showsStorageFallbackWarning = false
        UserDefaults.standard.set(true, forKey: Self.warnedStorageFallbackKey)
    }

    /// Archives idle tabs, then opens anything handed to us while we were away.
    func didBecomeActive() {
        sceneIsActive = true
        guard isLoaded else { return }
        stampActiveTab()
        state.runArchive(policy: Self.archivePolicy)
        openInboxAndPending()
        if state.activeTabID == nil, let first = state.activeSpaceTabs.first {
            state.activate(tabID: first.id)
        }
        stateDidChange()
    }

    /// The scene can be killed from here without a background transition; flush now.
    func didBecomeInactive() {
        sceneIsActive = false
        saveNow()
    }

    func didEnterBackground() {
        sceneIsActive = false
        stampActiveTab()
        if let activeSession { snapshot(activeSession) }
        saveNow()
    }

    /// `cormorant://open` drains the inbox (optionally with an http(s) `?url=`); plain web URLs open as tabs.
    func handle(openURL url: URL) {
        switch url.scheme?.lowercased() {
        case "cormorant":
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value.flatMap(URL.init(string:))
            if let target {
                if Self.isWeb(target) {
                    pendingURLs.append(target)
                } else {
                    Logger.app.notice("Dropped cormorant://open target with scheme \(target.scheme ?? "none", privacy: .public)")
                }
            }
        case "http", "https":
            pendingURLs.append(url)
        default:
            return
        }
        guard isLoaded else { return }
        openInboxAndPending()
        stateDidChange()
    }

    // MARK: Tabs

    func newTab() { open(nil) }

    func open(_ url: URL?) {
        guard isLoaded else {
            if let url { pendingURLs.append(url) }
            return
        }
        stampActiveTab()
        _ = state.openTab(url: url)
        if url == nil { addressFocusRequest += 1 }
        stateDidChange()
    }

    func activate(_ tabID: UUID) {
        stampActiveTab()
        state.activate(tabID: tabID)
        stateDidChange()
    }

    /// Archives the tab. Keeps at least one tab open.
    func close(_ tabID: UUID) {
        state.archive(tabID: tabID)
        if state.activeSpaceTabs.isEmpty { _ = state.openTab(url: nil) }
        stateDidChange()
    }

    func restore(_ archivedID: UUID) {
        stampActiveTab()
        state.restore(archivedID: archivedID)
        stateDidChange()
    }

    func deleteArchived(_ archivedID: UUID) {
        state.archived.removeAll { $0.id == archivedID }
        scheduleSave()
    }

    func clearArchive() {
        state.clearArchive()
        scheduleSave()
    }

    /// Runs address-bar text through the resolver and loads the result in the active tab.
    func submit(_ input: String) {
        guard let activeSession,
              let resolution = AddressResolver.resolve(input, engine: settings.searchEngine) else { return }
        switch resolution {
        case .navigate(let url), .search(let url, _):
            activeSession.load(url)
        }
    }

    // MARK: Blocking

    /// Flips blocking for the active page's host, re-applies rules in every tab on that site,
    /// and reloads the active one.
    func toggleBlockingForActiveSite() {
        guard let activeSession, let host = activeSession.webView.url?.host() else { return }
        let isBlocking = blocking.isBlocking(host: host)
        blocking.update { $0.setBlocking(!isBlocking, host: host) }
        let site = BlockingPreferences.normalize(host: host)
        for session in sessions.values {
            guard let sessionHost = session.webView.url?.host(),
                  BlockingPreferences.normalize(host: sessionHost) == site else { continue }
            session.reapplyBlocking(reload: session === activeSession)
        }
    }

    /// Applies a preferences change and refreshes rules in every live web view (no reload).
    func updateBlockingPreferences(_ change: (inout BlockingPreferences) -> Void) {
        blocking.update(change)
        reapplyBlockingEverywhere()
    }

    private func reapplyBlockingEverywhere() {
        for session in sessions.values { session.reapplyBlocking(reload: false) }
    }

    // MARK: Snapshots

    func snapshotActiveTab() {
        if let activeSession { snapshot(activeSession) }
    }

    private func snapshot(_ session: TabSession) {
        guard session.webView.window != nil, session.webView.url != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        let tabID = session.tabID
        Task {
            guard let image = try? await session.webView.takeSnapshot(configuration: configuration),
                  state.tabs.contains(where: { $0.id == tabID }) else { return }
            snapshots[tabID] = image
        }
    }

    // MARK: Internals

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Marks the active tab as just viewed. Call before the active tab changes (so the tab being left
    /// isn't auto-archived as if it had been idle since it was opened) and when the app goes away.
    private func stampActiveTab() {
        guard let id = state.activeTabID, let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs[index].lastViewedAt = .now
    }

    private func openInboxAndPending() {
        let requests: [OpenRequest]
        do {
            requests = try inbox?.drain() ?? []
        } catch {
            Logger.app.error("Shared inbox unreadable: \(error.localizedDescription, privacy: .public)")
            requests = []
        }
        let urls = (requests.map(\.url) + pendingURLs).filter(Self.isWeb)
        pendingURLs.removeAll()
        if !urls.isEmpty { stampActiveTab() }
        for url in urls { _ = state.openTab(url: url) }
        if state.activeSpaceTabs.isEmpty { _ = state.openTab(url: nil) }
    }

    /// `window.open` / `target=_blank`: a new active Today tab whose web view WebKit will navigate.
    private func openChild(configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView? {
        guard isLoaded else { return nil }
        // `window.open('')` has no URL yet; the opener navigates or writes into the new view.
        let requested = action.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
        stampActiveTab()
        let tab = state.openTab(url: requested ?? URL(string: "about:blank"))
        let session = makeSession(for: tab, configuration: configuration)
        session.installCachedBlocking(for: requested)
        stateDidChange()
        return session.webView
    }

    private func stateDidChange() {
        syncActiveSession()
        pruneSessions()
        scheduleSave()
    }

    private func syncActiveSession() {
        guard let tab = activeTab else {
            activeSession = nil
            return
        }
        guard activeSession?.tabID != tab.id else { return }
        if let activeSession { snapshot(activeSession) }
        let session = session(for: tab)
        activeSession = session
        session.didBecomeActiveTab()
        recentTabIDs.removeAll { $0 == tab.id }
        recentTabIDs.insert(tab.id, at: 0)
        for evicted in recentTabIDs.dropFirst(Self.liveWebViewLimit) {
            if let history = sessions[evicted]?.webView.interactionState { interactionStates[evicted] = history }
            sessions[evicted] = nil
        }
        recentTabIDs = Array(recentTabIDs.prefix(Self.liveWebViewLimit))
    }

    private func session(for tab: Tab) -> TabSession {
        if let existing = sessions[tab.id] { return existing }
        let session = makeSession(for: tab)
        session.start(loading: tab.url, restoring: interactionStates.removeValue(forKey: tab.id))
        return session
    }

    private func makeSession(for tab: Tab, configuration: WKWebViewConfiguration? = nil) -> TabSession {
        let session = TabSession(tabID: tab.id, blocking: blocking, configuration: configuration)
        let tabID = tab.id
        session.onPageChange = { [weak self] url, title in self?.pageDidChange(tabID: tabID, url: url, title: title) }
        session.onPageLoaded = { [weak self, weak session] in
            if let self, let session, session === self.activeSession { self.snapshot(session) }
        }
        session.onCreateWebView = { [weak self] configuration, action in
            self?.openChild(configuration: configuration, for: action)
        }
        session.onClose = { [weak self] in self?.close(tabID) }
        session.onProcessTerminated = { [weak self, weak session] in
            // Background tabs reload when they're next shown (`didBecomeActiveTab`).
            if let self, let session, session === self.activeSession { session.recoverFromCrash() }
        }
        sessions[tab.id] = session
        return session
    }

    private func pruneSessions() {
        let live = Set(state.tabs.map(\.id))
        sessions = sessions.filter { live.contains($0.key) }
        interactionStates = interactionStates.filter { live.contains($0.key) }
        recentTabIDs.removeAll { !live.contains($0) }
        if snapshots.keys.contains(where: { !live.contains($0) }) {
            snapshots = snapshots.filter { live.contains($0.key) }
        }
    }

    private func pageDidChange(tabID: UUID, url: URL?, title: String) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        state.update(tabID: tabID, url: url ?? state.tabs[index].url, title: title)
        if tabID == state.activeTabID { state.tabs[index].lastViewedAt = .now }
        scheduleSave()
    }

    // MARK: Saving

    /// Saving is off until the state is loaded, and while a load failure is unacknowledged.
    private var canSave: Bool { isLoaded && loadFailure == nil }

    /// Debounced while the scene is active; immediate otherwise, since the process may not get another chance.
    private func scheduleSave() {
        guard canSave else { return }
        guard sceneIsActive else {
            saveNow()
            return
        }
        // Coalesce: a pending save already covers this change. Restarting the timer on every
        // title/URL change would let a busy page (ticking title, unread counts) postpone saving forever.
        guard debouncedSave == nil else { return }
        debouncedSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            debouncedSave = nil
            enqueueSave()
        }
    }

    private func saveNow() {
        guard canSave else { return }
        debouncedSave?.cancel()
        debouncedSave = nil
        let application = UIApplication.shared
        let backgroundTask = application.beginBackgroundTask(withName: "Save tabs", expirationHandler: nil)
        let save = enqueueSave()
        Task {
            await save.value
            application.endBackgroundTask(backgroundTask)
        }
    }

    /// Appends a write of the current state to the save chain.
    @discardableResult
    private func enqueueSave() -> Task<Void, Never> {
        saveSequence += 1
        let sequence = saveSequence
        let snapshot = state
        let previous = saveChain
        let task = Task { [stateStore] in
            await previous?.value
            // The chain already orders writes; this keeps the invariant explicit.
            guard sequence > self.lastWrittenSequence else { return }
            do {
                try await stateStore.save(snapshot)
                self.lastWrittenSequence = sequence
            } catch {
                Logger.app.error("Saving tabs failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        saveChain = task
        return task
    }

    /// For load errors other than `unreadable` the store didn't move the file; copy it aside so
    /// Start Fresh can't destroy the only copy. Returns the copy's file name.
    private func keepCopyOfStateFile() async -> String? {
        guard let fileStore = stateStore as? JSONBrowserStateStore else { return nil }
        let source = await fileStore.fileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "")
        let copy = source.deletingLastPathComponent().appending(path: "browser-state.unreadable-\(stamp).json")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            return copy.lastPathComponent
        } catch {
            Logger.app.fault("Couldn't copy unreadable tabs aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
