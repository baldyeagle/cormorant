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
    /// Background tabs that load at once. Each is a full-size page painting in its own web content
    /// process until it's snapshotted; more would compete with the page on screen for memory and CPU.
    static let backgroundLoadLimit = 2
    /// A background page that hasn't finished by now (long polling, a hung subresource) is snapshotted
    /// as it is and taken off the stage.
    static let backgroundLoadTimeout: Duration = .seconds(20)
    private static let warnedStorageFallbackKey = "warnedAppGroupUnavailable"

    private(set) var state = BrowserState.empty
    private(set) var isLoaded = false
    private(set) var loadFailure: LoadFailure?
    /// The app group was unavailable and tabs are stored in Application Support instead. Shown once.
    private(set) var showsStorageFallbackWarning = false
    private(set) var activeSession: TabSession?
    private(set) var snapshots: [UUID: UIImage] = [:]
    /// Bumped to ask the browser screen to open the search panel.
    private(set) var addressFocusRequest = 0
    /// New Tab was chosen and the search panel is composing it. No tab exists until a submit;
    /// dismissing the panel, switching tabs or an external open drops the intent.
    private(set) var isComposingNewTab = false

    let blocking: BlockingService
    let settings: AppSettings
    let favicons: FaviconStore

    @ObservationIgnored private let stateStore: any BrowserStateStore
    @ObservationIgnored private let historyStore: TabHistoryStore
    @ObservationIgnored private let inbox: SharedInbox?
    @ObservationIgnored private var sessions: [UUID: TabSession] = [:]
    @ObservationIgnored private var recentTabIDs: [UUID] = []
    /// Back/forward history of tabs with no web view (evicted, or not shown since launch), restored
    /// when they're built.
    @ObservationIgnored private var interactionStates: [UUID: Any] = [:]
    /// What `historyStore` holds, so only histories that changed are written.
    @ObservationIgnored private var savedHistories: [UUID: Data] = [:]
    /// Tabs that went to another page since their history was last saved.
    @ObservationIgnored private var navigatedTabIDs: Set<UUID> = []
    /// Tail of the history save chain, like `saveChain`.
    @ObservationIgnored private var historySaveChain: Task<Void, Never>?
    /// Zoom and desktop mode to give a tab's web view when it's next built: an evicted tab's own, or
    /// those a link-menu tab inherits from its opener. Memory only.
    @ObservationIgnored private var pendingViewSettings: [UUID: TabSession.ViewSettings] = [:]
    /// Background tabs loading on the stage, with the timers that give up waiting for them.
    @ObservationIgnored private var stagedLoads: [UUID: Task<Void, Never>] = [:]
    /// Background tabs waiting for a stage slot, oldest first. They have no web view yet.
    @ObservationIgnored private var backgroundQueue: [UUID] = []
    @ObservationIgnored private let backgroundStage = BackgroundPageStage()
    /// Where background tabs load, and at what size: the window and layout of the tab they were opened
    /// from, so they're ready to show as they are.
    @ObservationIgnored private weak var stagingWindow: UIWindow?
    @ObservationIgnored private var stagingLayout: PageLayout?
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var sceneIsActive = true
    @ObservationIgnored private var debouncedSave: Task<Void, Never>?
    /// Tail of the save chain. Every save waits for the one before it, so writes land in order.
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var saveSequence = 0
    @ObservationIgnored private var lastWrittenSequence = 0
    /// What the file holds once the save chain drains: the loaded state, then each queued write.
    /// Nil when unknown (load failed, a write failed), so the next save writes.
    @ObservationIgnored private var lastSavedState: BrowserState?

    init(
        stateStore: (any BrowserStateStore)? = nil,
        historyStore: TabHistoryStore = TabHistoryStore(),
        blocking: BlockingService = BlockingService(),
        settings: AppSettings = AppSettings(),
        favicons: FaviconStore = FaviconStore(),
        receivesSharedLinks: Bool = true
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
        self.historyStore = historyStore
        inbox = receivesSharedLinks ? SharedInbox(appGroup: AppGroup.identifier) : nil
        if receivesSharedLinks, inbox == nil {
            Logger.app.fault("App group unavailable: shared links can't be received.")
        }
        self.blocking = blocking
        self.settings = settings
        self.favicons = favicons
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
            lastSavedState = state
            savedHistories = await historyStore.load(keeping: Set(state.tabs.map(\.id)))
            interactionStates = savedHistories
        } catch BrowserStateStoreError.unreadable(let quarantinedTo, let underlying) {
            Logger.app.fault("Saved tabs unreadable (\(underlying, privacy: .public)); moved to \(quarantinedTo?.path ?? "nowhere", privacy: .public). Saving is off until Start Fresh.")
            state = .empty
            loadFailure = LoadFailure(keptCopyName: quarantinedTo?.lastPathComponent)
        } catch {
            Logger.app.fault("Loading saved tabs failed: \(error.localizedDescription, privacy: .public). Saving is off until Start Fresh.")
            state = .empty
            loadFailure = LoadFailure(keptCopyName: await keepCopyOfStateFile())
        }
        dropBlankTabs()
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
        saveHistories()
    }

    func didEnterBackground() {
        sceneIsActive = false
        stampActiveTab()
        if let activeSession { snapshot(activeSession) }
        saveNow()
        saveHistories()
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

    /// Opens the search panel to compose a new tab. The tab is created by `submit(_:)`, so
    /// backing out leaves the tab count unchanged.
    func newTab() {
        guard isLoaded else { return }
        isComposingNewTab = true
        addressFocusRequest += 1
    }

    /// The search panel closed without submitting.
    func cancelComposing() {
        isComposingNewTab = false
    }

    func activate(_ tabID: UUID) {
        isComposingNewTab = false
        stampActiveTab()
        state.activate(tabID: tabID)
        stateDidChange()
    }

    /// Archives the tab. Closing the last one leaves the Space empty (no active tab).
    func close(_ tabID: UUID) {
        state.archive(tabID: tabID)
        stateDidChange()
    }

    /// Whether swiping back from this tab's first page closes it (a link opened it).
    func closesOnBackSwipe(_ tabID: UUID) -> Bool {
        state.tabs.first { $0.id == tabID }?.openedFromLink == true
    }

    /// The last snapshot of the tab `close(_:)` would land on, to show under the page while it's
    /// swiped away.
    func backSwipeSnapshot(for tabID: UUID) -> UIImage? {
        state.tabAfterArchiving(tabID).flatMap { snapshots[$0] }
    }

    func restore(_ archivedID: UUID) {
        isComposingNewTab = false
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
        // The icon cache is named by host: keep only what open tabs still show.
        favicons.forgetSites(except: state.tabs.compactMap(\.url))
        scheduleSave()
    }

    /// Runs address-bar text through the resolver and loads the result: in a new tab when composing
    /// one (or when there is no tab at all), otherwise in the active tab.
    func submit(_ input: String) {
        guard isLoaded, let resolution = AddressResolver.resolve(input, engine: settings.searchEngine) else { return }
        let url: URL
        switch resolution {
        case .navigate(let target), .search(let target, _):
            url = target
        }
        if isComposingNewTab || activeSession == nil {
            isComposingNewTab = false
            stampActiveTab()
            _ = state.openTab(url: url)
            stateDidChange()
        } else {
            activeSession?.load(url)
        }
    }

    /// A link from a page's long-press menu, opened in a new tab: switched to, or loaded in the
    /// background with the current page still on screen. With a `handoff` the tab adopts the menu
    /// preview's web view, page and all; otherwise it loads the link. Either way it gets the opener's
    /// zoom and desktop/mobile choice, as the preview (and a `target=_blank` popup) does.
    /// Returns false if no tab was opened.
    @discardableResult
    func openLinkInNewTab(_ url: URL, inBackground: Bool, from opener: TabSession?, handoff: LinkPreviewHandoff?) -> Bool {
        guard isLoaded, Self.isWeb(url) else { return false }
        if !inBackground {
            isComposingNewTab = false
            stampActiveTab()
        }
        // An adopted page may have redirected; the tab records where it ended up. Like any tab a link
        // opens, swiping back from its first page closes it.
        let tab = state.openTab(url: handoff?.webView.url ?? url, title: handoff?.webView.title ?? "",
                                activate: !inBackground, fromLink: true)
        // Stamped after, so the page being read stays first in the switcher, the new tab next.
        if inBackground { stampActiveTab() }
        if let handoff {
            let session = makeSession(for: tab, adopting: handoff)
            // Its page may be in already, so no `didFinish` will say so: its one-entry history is
            // saved and its icon fetched now (a page still loading gets both again when it finishes).
            navigatedTabIDs.insert(tab.id)
            if !session.webView.isLoading { favicons.pageDidLoad(in: session.webView) }
        } else if let opener {
            pendingViewSettings[tab.id] = opener.viewSettings
        }
        if inBackground {
            if let opener, let window = opener.webView.window {
                stagingWindow = window
                stagingLayout = PageLayout(of: opener.webView)
            }
            loadInBackground(tab.id)
        }
        stateDidChange()
        if handoff != nil { saveHistories(onlyNavigated: true) }
        return true
    }

    // MARK: Blocking

    /// Flips blocking for the active page's host, re-applies rules in every tab on that site,
    /// and reloads the active one.
    func toggleBlockingForActiveSite() {
        // The tab's URL covers a web view that hasn't loaded yet (rebuilt after eviction, failed first load).
        guard let activeSession, let host = (activeSession.webView.url ?? activeTab?.url)?.host() else { return }
        let isBlocking = blocking.isBlocking(host: host)
        blocking.update { $0.setBlocking(!isBlocking, host: host) }
        let site = BlockingPreferences.normalize(host: host)
        for session in sessions.values {
            // The active one always, even with no URL yet: its first navigation then re-checks the rules.
            guard session === activeSession || session.webView.url?.host()
                .map(BlockingPreferences.normalize(host:)) == site else { continue }
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

    @discardableResult
    private func snapshot(_ session: TabSession) -> Task<Void, Never>? {
        guard session.webView.window != nil, session.webView.url != nil else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        let tabID = session.tabID
        return Task {
            guard let image = try? await session.webView.takeSnapshot(configuration: configuration),
                  state.tabs.contains(where: { $0.id == tabID }) else { return }
            snapshots[tabID] = image
        }
    }

    // MARK: Background loads

    /// Background tabs load now rather than when first shown, so the switcher has their page by the
    /// time it's opened. A tab adopting a preview's page has its web view already and goes straight
    /// on the stage; others queue for one of `backgroundLoadLimit` slots.
    private func loadInBackground(_ tabID: UUID) {
        if let session = sessions[tabID] {
            stage(session)
            keepLive(tabID, inBackground: true)
        } else {
            backgroundQueue.append(tabID)
            startQueuedBackgroundLoads()
        }
    }

    /// With nowhere to stage (no window seen yet), queued tabs wait to load until they're shown.
    private func startQueuedBackgroundLoads() {
        guard stagingWindow != nil else { return }
        while stagedLoads.count < Self.backgroundLoadLimit, !backgroundQueue.isEmpty {
            let tabID = backgroundQueue.removeFirst()
            // Shown, closed, or given a web view some other way meanwhile.
            guard sessions[tabID] == nil, tabID != state.activeTabID,
                  let tab = state.tabs.first(where: { $0.id == tabID }) else { continue }
            let session = session(for: tab)
            stage(session)
            keepLive(tabID, inBackground: true)
        }
    }

    /// Without a window to stage in, the page still loads but is snapshotted only once shown.
    private func stage(_ session: TabSession) {
        guard let window = stagingWindow, let layout = stagingLayout else { return }
        let tabID = session.tabID
        backgroundStage.add(session.webView, layout: layout, in: window)
        stagedLoads[tabID] = Task { [weak self] in
            try? await Task.sleep(for: Self.backgroundLoadTimeout)
            if !Task.isCancelled { self?.finishBackgroundLoad(tabID) }
        }
        // An adopted page may be loaded already: no `didFinish` to wait for. A moment on the stage
        // first, so the snapshot has it painted at its new size.
        if session.webView.url != nil, !session.webView.isLoading {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.finishBackgroundLoad(tabID)
            }
        }
    }

    /// Snapshots a background page for the switcher, then takes it off the stage so it stops
    /// painting. Its web view stays live (within `liveWebViewLimit`) for when the tab is shown.
    private func finishBackgroundLoad(_ tabID: UUID, snapshot takesSnapshot: Bool = true) {
        guard let timer = stagedLoads.removeValue(forKey: tabID) else { return }
        timer.cancel()
        if let session = sessions[tabID], session !== activeSession {
            if takesSnapshot, let snapshotting = snapshot(session) {
                // The web view, not the session: the tab may close or be evicted meanwhile, and its
                // web view must still leave the stage.
                let webView = session.webView
                Task { [weak self] in
                    await snapshotting.value
                    self?.backgroundStage.remove(webView)
                }
            } else {
                backgroundStage.remove(session.webView)
            }
        }
        startQueuedBackgroundLoads()
    }

    /// The tab is being shown, closed or evicted: it no longer loads in the background. A tab being
    /// shown stays where it is; the on-screen container takes its web view off the stage.
    private func cancelBackgroundLoad(_ tabID: UUID, unstaging: Bool) {
        backgroundQueue.removeAll { $0 == tabID }
        guard let timer = stagedLoads.removeValue(forKey: tabID) else { return }
        timer.cancel()
        if unstaging, let session = sessions[tabID] { backgroundStage.remove(session.webView) }
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
        guard !urls.isEmpty else { return }
        isComposingNewTab = false
        stampActiveTab()
        for url in urls { _ = state.openTab(url: url) }
    }

    /// Build one kept a URL-less placeholder tab alive; tabs now exist only with a page, so drop any
    /// left in saved state. An empty Space is valid and shows the search panel.
    private func dropBlankTabs() {
        guard state.tabs.contains(where: { $0.url == nil }) else { return }
        state.tabs.removeAll { $0.url == nil }
        if let id = state.activeTabID, !state.tabs.contains(where: { $0.id == id }) {
            state.activeTabID = nil
        }
    }

    /// `window.open` / `target=_blank`: a new active Today tab whose web view WebKit will navigate.
    private func openChild(configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                           from opener: TabSession?) -> WKWebView? {
        guard isLoaded else { return nil }
        isComposingNewTab = false
        // `window.open('')` has no URL yet; the opener navigates or writes into the new view.
        let requested = action.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
        stampActiveTab()
        let tab = state.openTab(url: requested ?? URL(string: "about:blank"), fromLink: true)
        let session = makeSession(for: tab, configuration: configuration)
        // Before WebKit navigates it, so a popup from a desktop-mode tab opens in desktop mode too.
        if let opener { session.apply(opener.viewSettings) }
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
            activeSession?.didResignActiveTab()
            activeSession = nil
            return
        }
        guard activeSession?.tabID != tab.id else { return }
        activeSession?.didResignActiveTab()
        if let activeSession { snapshot(activeSession) }
        cancelBackgroundLoad(tab.id, unstaging: false)
        let session = session(for: tab)
        activeSession = session
        session.didBecomeActiveTab()
        keepLive(tab.id, inBackground: false)
        startQueuedBackgroundLoads()
    }

    /// Marks the tab's web view as recently used: first for the tab being shown; last for a background
    /// tab, which ranks behind every tab the user has looked at. Past `liveWebViewLimit` the least
    /// recent web views are released (keeping their history to rebuild from), never the tab on screen,
    /// one still loading in the background, or the one just added. So opening many background tabs can't
    /// push out the pages being read, and memory stays at the limit plus the background slots.
    private func keepLive(_ tabID: UUID, inBackground: Bool) {
        recentTabIDs.removeAll { $0 == tabID }
        if inBackground { recentTabIDs.append(tabID) } else { recentTabIDs.insert(tabID, at: 0) }
        while recentTabIDs.count > Self.liveWebViewLimit,
              let evicted = recentTabIDs.last(where: {
                  $0 != tabID && $0 != state.activeTabID && stagedLoads[$0] == nil
              }) {
            recentTabIDs.removeAll { $0 == evicted }
            cancelBackgroundLoad(evicted, unstaging: true)
            if let session = sessions.removeValue(forKey: evicted) {
                backgroundStage.remove(session.webView)
                if let history = session.webView.interactionState {
                    interactionStates[evicted] = history
                    navigatedTabIDs.insert(evicted)
                }
                pendingViewSettings[evicted] = session.viewSettings
            }
        }
    }

    private func session(for tab: Tab) -> TabSession {
        if let existing = sessions[tab.id] { return existing }
        let session = makeSession(for: tab)
        if let settings = pendingViewSettings.removeValue(forKey: tab.id) { session.apply(settings) }
        session.start(loading: tab.url, restoring: interactionStates.removeValue(forKey: tab.id))
        return session
    }

    @discardableResult
    private func makeSession(for tab: Tab, configuration: WKWebViewConfiguration? = nil,
                             adopting handoff: LinkPreviewHandoff? = nil) -> TabSession {
        let session = handoff.map { TabSession(tabID: tab.id, blocking: blocking, adopting: $0) }
            ?? TabSession(tabID: tab.id, blocking: blocking, configuration: configuration)
        let tabID = tab.id
        session.onPageChange = { [weak self] url, title in self?.pageDidChange(tabID: tabID, url: url, title: title) }
        session.onPageLoaded = { [weak self, weak session] in
            guard let self, let session else { return }
            if session === self.activeSession {
                self.snapshot(session)
            } else if self.stagedLoads[tabID] != nil {
                self.finishBackgroundLoad(tabID)
            }
            self.favicons.pageDidLoad(in: session.webView)
            // The URL changes when a navigation starts; the history only has the new page once it's in.
            self.navigatedTabIDs.insert(tabID)
            self.saveHistories(onlyNavigated: true)
        }
        session.onCreateWebView = { [weak self, weak session] configuration, action in
            self?.openChild(configuration: configuration, for: action, from: session)
        }
        session.onOpenInNewTab = { [weak self, weak session] url, inBackground, handoff in
            self?.openLinkInNewTab(url, inBackground: inBackground, from: session, handoff: handoff) ?? false
        }
        session.onClose = { [weak self] in self?.close(tabID) }
        session.onProcessTerminated = { [weak self, weak session] in
            // Background tabs reload when they're next shown (`didBecomeActiveTab`).
            guard let self, let session else { return }
            if session === self.activeSession {
                session.recoverFromCrash()
            } else {
                self.finishBackgroundLoad(tabID, snapshot: false)
            }
        }
        sessions[tab.id] = session
        return session
    }

    private func pruneSessions() {
        let live = Set(state.tabs.map(\.id))
        for tabID in Set(stagedLoads.keys).union(backgroundQueue) where !live.contains(tabID) {
            cancelBackgroundLoad(tabID, unstaging: true)
        }
        // Whatever state a closed tab's web view was in, it doesn't stay on the stage.
        for (tabID, session) in sessions where !live.contains(tabID) {
            backgroundStage.remove(session.webView)
        }
        sessions = sessions.filter { live.contains($0.key) }
        interactionStates = interactionStates.filter { live.contains($0.key) }
        pendingViewSettings = pendingViewSettings.filter { live.contains($0.key) }
        recentTabIDs.removeAll { !live.contains($0) }
        if snapshots.keys.contains(where: { !live.contains($0) }) {
            snapshots = snapshots.filter { live.contains($0.key) }
        }
    }

    private func pageDidChange(tabID: UUID, url: URL?, title: String) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if let url, url != state.tabs[index].url { navigatedTabIDs.insert(tabID) }
        state.update(tabID: tabID, url: url ?? state.tabs[index].url, title: title)
        if tabID == state.activeTabID { state.tabs[index].lastViewedAt = .now }
        scheduleSave()
    }

    // MARK: Saving

    /// Saving is off until the state is loaded, and while a load failure is unacknowledged.
    private var canSave: Bool { isLoaded && loadFailure == nil }

    /// Saving is allowed and the state differs from what's on disk (a fresh install with no tabs never writes).
    private var needsSave: Bool { canSave && state != lastSavedState }

    /// Debounced while the scene is active; immediate otherwise, since the process may not get another chance.
    private func scheduleSave() {
        guard needsSave else { return }
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
            if needsSave { enqueueSave() }
            // Not only when the app goes away: it can be killed without that (a crash, a watchdog).
            saveHistories(onlyNavigated: true)
        }
    }

    private func saveNow() {
        guard canSave else { return }
        debouncedSave?.cancel()
        debouncedSave = nil
        // Unchanged: nothing to write, but a write already in flight still gets the background time.
        guard let save = needsSave ? enqueueSave() : saveChain else { return }
        keepRunning(until: save, named: "Save tabs")
    }

    /// Asks for background time until `task` finishes, so a write isn't cut off by suspension.
    private func keepRunning(until task: Task<Void, Never>, named name: String) {
        let application = UIApplication.shared
        let backgroundTask = application.beginBackgroundTask(withName: name, expirationHandler: nil)
        Task {
            await task.value
            application.endBackgroundTask(backgroundTask)
        }
    }

    /// Writes each tab's back/forward history that changed since the last save, so it survives a
    /// relaunch, and drops those of closed tabs. `onlyNavigated` limits it to tabs that went to another
    /// page, for the saves made while browsing; when the app may be suspended, every tab is checked.
    private func saveHistories(onlyNavigated: Bool = false) {
        guard canSave else { return }
        let tabIDs = onlyNavigated ? navigatedTabIDs : Set(sessions.keys).union(interactionStates.keys)
        navigatedTabIDs.subtract(tabIDs)
        var current: [UUID: Data] = [:]
        for tabID in tabIDs {
            guard let session = sessions[tabID] else {
                if let history = interactionStates[tabID] as? Data { current[tabID] = history }
                continue
            }
            if session.isRestoringHistory {
                // Its web view's history is still empty.
                if let pending = session.pendingHistory as? Data { current[tabID] = pending }
            } else if session.webView.backForwardList.currentItem != nil,
                      let history = session.webView.interactionState as? Data {
                // Not a web view that never loaded a page: nothing to keep. (One whose content process
                // crashed has no `url` but keeps its history.)
                current[tabID] = history
            }
        }
        let live = Set(state.tabs.map(\.id))
        let changed = current.filter { live.contains($0.key) && savedHistories[$0.key] != $0.value }
        let closed = savedHistories.keys.filter { !live.contains($0) }
        guard !changed.isEmpty || !closed.isEmpty else {
            // Nothing new, but a write queued while browsing may still be in flight: give it background time.
            if !sceneIsActive, let inFlight = historySaveChain { keepRunning(until: inFlight, named: "Save tab history") }
            return
        }
        savedHistories.merge(changed) { $1 }
        for tabID in closed { savedHistories[tabID] = nil }

        let previous = historySaveChain
        let save = Task { [historyStore] in
            await previous?.value
            let failed = await historyStore.save(changed, live: live)
            // Written again at the next save, unless a newer history has been queued meanwhile.
            for tabID in failed where savedHistories[tabID] == changed[tabID] {
                savedHistories[tabID] = nil
                navigatedTabIDs.insert(tabID)
            }
        }
        historySaveChain = save
        if !sceneIsActive { keepRunning(until: save, named: "Save tab history") }
    }

    /// Appends a write of the current state to the save chain.
    @discardableResult
    private func enqueueSave() -> Task<Void, Never> {
        saveSequence += 1
        let sequence = saveSequence
        let snapshot = state
        // Set when queued, not when written: writes land in order, so a state that changes and changes
        // back while one is in flight still gets its own write after it.
        lastSavedState = snapshot
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
                self.lastSavedState = nil
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
