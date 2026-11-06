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
    private(set) var snapshots: [UUID: PageSnapshot] = [:]
    /// Bumped to ask the browser screen to open the search panel.
    private(set) var addressFocusRequest = 0
    /// New Tab was chosen and the search panel is composing it. No tab exists until a submit;
    /// dismissing the panel, switching tabs or an external open drops the intent.
    private(set) var isComposingNewTab = false
    /// The search panel is open to search open tabs only (Search Tabs). Dropped with the panel.
    private(set) var isSearchingTabs = false
    /// Manage Spaces is up, or asked for. Set by `showManageSpaces()` / `dismissManageSpaces()`
    /// (BrowserStore+Spaces.swift).
    var showsManageSpaces = false
    /// Bumped by each `showManageSpaces()`, to ask the browser to close whatever else is up and present
    /// it. On an ask while it's meant to be up already, the browser presents it afresh, so one
    /// presentation that didn't take can't leave the way in dead (`BrowserView.presentManageSpaces`).
    var manageSpacesRequest = 0
    /// A Space whose Edit Space opens on top of Manage Spaces once it's up (a strip icon's Edit).
    var spaceToEdit: UUID?
    /// Manage Spaces is showing as a page in Settings. While it is, a change of active tab (from
    /// archiving, deleting or switching Spaces there) leaves the caret sheet and Settings up.
    @ObservationIgnored var isManagingSpacesInSettings = false
    /// Bumped to ask the browser to close the search panel, the caret sheet and Settings on it: a Space
    /// just added (so you land in it) and a link from another app (straight to the page).
    var closeSheetsRequest = 0
    /// The toast on screen, if any (`showToast(_:)`).
    private(set) var toast: Toast?
    /// Toasts put up since launch, for UI tests (`UITestingProbes`).
    @ObservationIgnored private(set) var toastsShown = 0
    /// A tab the Move to Space sheet is asked up for, from a toast (BrowserStore+MoveTabs.swift).
    var moveRequest: MoveRequest?

    let blocking: BlockingService
    let settings: AppSettings
    let favicons: FaviconStore
    let defaultBrowser: DefaultBrowserStatus
    /// Pages visited, for the search panel. Nil if the database couldn't be opened; browsing goes on
    /// without it.
    let browsingHistory: BrowsingHistory?
    /// Asks the search engine for suggestions; nil never asks (UI tests).
    let searchSuggestions: SearchSuggestionClient?
    /// The Space a Focus filter sends links from other apps to, while one is on.
    let focusFilter: FocusFilterSettings

    @ObservationIgnored private let stateStore: any BrowserStateStore
    @ObservationIgnored private let historyStore: TabHistoryStore
    @ObservationIgnored private let inbox: SharedInbox?
    /// Where the Spaces are summed up for the share extension and the Focus filter's Space list.
    @ObservationIgnored private let spacesSummary: SpacesSummaryFile?
    /// What `spacesSummary` holds, as far as this launch knows: written again only when it changes.
    @ObservationIgnored private var writtenSummary: SpacesSummary?
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
    /// Tail of the browsing-history write chain, so a page's title never lands before its visit.
    @ObservationIgnored private var browsingHistoryChain: Task<Void, Never>?
    /// Tabs opened for a page not yet shown, whose first load is a visit. Any other tab's first load
    /// (restored at launch, rebuilt after its web view was let go) brings back a page already counted.
    @ObservationIgnored private var unvisitedTabIDs: Set<UUID> = []
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
    /// Links from other apps waiting for the tabs to load, each with the Space it was sent to, if any.
    @ObservationIgnored private var pendingURLs: [(url: URL, spaceID: UUID?)] = []
    @ObservationIgnored private var sceneIsActive = true
    @ObservationIgnored private var debouncedSave: Task<Void, Never>?
    /// Tail of the save chain. Every save waits for the one before it, so writes land in order.
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var saveSequence = 0
    @ObservationIgnored private var lastWrittenSequence = 0
    /// Tab-list and history writes queued or running.
    @ObservationIgnored private var writesInFlight = 0
    /// What the file holds once the save chain drains: the loaded state, then each queued write.
    /// Nil when unknown (load failed, a write failed), so the next save writes.
    @ObservationIgnored private var lastSavedState: BrowserState?
    /// Takes the toast down once its time is up.
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?
    /// Erasing deleted profiles' website data and history, while it runs (BrowserStore+Profiles.swift).
    @ObservationIgnored var profileErasure: Task<Void, Never>?
    /// Erasing was asked for again while it ran: it runs once more when done.
    @ObservationIgnored var erasesProfilesAgain = false

    init(
        stateStore: (any BrowserStateStore)? = nil,
        historyStore: TabHistoryStore = TabHistoryStore(),
        blocking: BlockingService = BlockingService(),
        settings: AppSettings = AppSettings(),
        favicons: FaviconStore = FaviconStore(),
        defaultBrowser: DefaultBrowserStatus = DefaultBrowserStatus(),
        browsingHistory: BrowsingHistory? = BrowserStore.openBrowsingHistory(),
        searchSuggestions: SearchSuggestionClient? = SearchSuggestionClient(),
        focusFilter: FocusFilterSettings = .shared,
        inbox: SharedInbox? = SharedInbox(appGroup: AppGroup.identifier),
        spacesSummary: SpacesSummaryFile? = SpacesSummaryFile(appGroup: AppGroup.identifier)
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
        self.inbox = inbox
        self.spacesSummary = spacesSummary
        if inbox == nil {
            Logger.app.fault("App group unavailable: shared links can't be received.")
        }
        self.blocking = blocking
        self.settings = settings
        self.favicons = favicons
        self.defaultBrowser = defaultBrowser
        self.browsingHistory = browsingHistory
        self.searchSuggestions = searchSuggestions
        self.focusFilter = focusFilter
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
        #if DEBUG
        seedUITestingSpaces()
        state = Self.uiTestingLaunchState(state)
        #endif
        isLoaded = true
        #if DEBUG
        removeUITestingDataStores()
        #endif
        writeBrowsingHistory { await $0.prune() }
        forgetFavicons()
        Task { await blocking.refresh() }
        didBecomeActive()
    }

    /// The user accepted losing the unreadable tabs; saving resumes with the current state.
    func startFresh() {
        loadFailure = nil
        saveNow()
        eraseDeletedProfiles()
    }

    func dismissStorageFallbackWarning() {
        showsStorageFallbackWarning = false
        UserDefaults.standard.set(true, forKey: Self.warnedStorageFallbackKey)
    }

    /// Archives idle tabs, then opens anything handed to us while we were away.
    func didBecomeActive() {
        sceneIsActive = true
        defaultBrowser.didBecomeActive()
        focusFilter.refresh()
        guard isLoaded else { return }
        stampActiveTab()
        state.runArchive()
        openInboxAndPending()
        if state.activeTabID == nil, let first = state.activeSpaceTabs.first {
            state.activate(tabID: first.id)
        }
        stateDidChange()
        // Deleted profiles whose data couldn't go last time (a web view still held it).
        eraseDeletedProfiles()
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

    /// `cormorant://open` drains the inbox (optionally with an http(s) `?url=`, and the `&space=` ID the
    /// share extension picked for it); plain web URLs open as tabs.
    func handle(openURL url: URL) {
        #if DEBUG
        if handleUITestingURL(url) { return }
        #endif
        switch url.scheme?.lowercased() {
        case "cormorant":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let target = query.first { $0.name == "url" }?.value.flatMap(URL.init(string:))
            let spaceID = query.first { $0.name == "space" }?.value.flatMap(UUID.init(uuidString:))
            if let target {
                if Self.isWeb(target) {
                    pendingURLs.append((target, spaceID))
                } else {
                    Logger.app.notice("Dropped cormorant://open target with scheme \(target.scheme ?? "none", privacy: .public)")
                }
            }
        case "http", "https":
            defaultBrowser.didReceiveWebURL()
            pendingURLs.append((url, nil))
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

    /// Opens the search panel to search open tabs only.
    func searchTabs() {
        guard isLoaded else { return }
        isComposingNewTab = false
        isSearchingTabs = true
        addressFocusRequest += 1
    }

    /// The search panel's Tabs token was removed: back to searching everything, editing this tab.
    func stopSearchingTabs() {
        isSearchingTabs = false
    }

    /// The search panel closed without submitting.
    func cancelComposing() {
        isComposingNewTab = false
        isSearchingTabs = false
    }

    func activate(_ tabID: UUID) {
        isComposingNewTab = false
        isSearchingTabs = false
        stampActiveTab()
        state.activate(tabID: tabID)
        stateDidChange()
    }

    // MARK: Spaces

    /// More than one Space to switch between. Until then nothing of Spaces shows.
    var hasSpacesToSwitch: Bool { state.hasSpacesToSwitch }

    /// The active Space, with its look and tab count, when there are Spaces to switch between; nil
    /// with only Home, where the bar and switcher look as they always have.
    var shownSpace: Space? { hasSpacesToSwitch ? state.activeSpace : nil }

    /// Shows the Space's most recently viewed tab, or the search panel when it has none. Web views of
    /// the Space left stay as they are (`liveWebViewLimit` spans Spaces).
    func switchToSpace(_ spaceID: UUID) {
        guard isLoaded, spaceID != state.activeSpaceID else { return }
        isComposingNewTab = false
        isSearchingTabs = false
        state.switchToSpace(spaceID)
        stateDidChange()
    }

    /// Applies `change` to the state, then shows and saves the result: for extensions in other files
    /// (BrowserStore+Spaces.swift), which can't set `state`. Leaving the active Space ends any
    /// composing or tab search, as switching tabs does. No-op until tabs are loaded.
    func changeState(_ change: (inout BrowserState) -> Void) {
        guard isLoaded else { return }
        let spaceID = state.activeSpaceID
        change(&state)
        if state.activeSpaceID != spaceID {
            isComposingNewTab = false
            isSearchingTabs = false
        }
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
    func backSwipeSnapshot(for tabID: UUID) -> PageSnapshot? {
        state.tabAfterArchiving(tabID).flatMap { snapshots[$0] }
    }

    func restore(_ archivedID: UUID) {
        isComposingNewTab = false
        stampActiveTab()
        state.restore(archivedID: archivedID)
        stateDidChange()
    }

    func deleteArchived(_ archivedID: UUID) {
        state.deleteArchived(archivedID)
        scheduleSave()
    }

    func clearArchive() {
        state.clearArchive()
        scheduleSave()
        forgetFavicons()
    }

    /// Forgets pages visited since `date`, or all of them.
    func clearHistory(since date: Date?) {
        writeBrowsingHistory { history in
            if let date { await history.removePages(visitedSince: date) } else { await history.removeAll() }
        }
        forgetFavicons()
    }

    /// Runs address-bar text through the resolver and loads the result: in a new tab when composing
    /// one, asked to, or when there is no tab at all; otherwise in the active tab.
    func submit(_ input: String, inNewTab: Bool = false) {
        guard isLoaded, let resolution = AddressResolver.resolve(input, engine: settings.searchEngine) else { return }
        if inNewTab { isComposingNewTab = true }
        switch resolution {
        case .navigate(let url): go(to: url, typed: true)
        case .search(let url, _): go(to: url, typed: false)
        }
    }

    /// Searches for `query` as written, even if it looks like an address (a search suggestion).
    func search(_ query: String) {
        guard isLoaded, let url = settings.searchEngine.url(for: query) ?? SearchEngine.default.url(for: query)
        else { return }
        go(to: url, typed: false)
    }

    /// A page from the search panel's history rows, loaded as `submit(_:)` loads an address.
    func open(historyPage url: URL) {
        guard isLoaded, Self.isWeb(url) else { return }
        go(to: url, typed: true)
    }

    /// Loads `url` in a new tab when composing one (or when there is no tab at all), otherwise in the
    /// active tab. `typed`: the user chose this page itself, not a search for it.
    private func go(to url: URL, typed: Bool) {
        isSearchingTabs = false
        // Counted where the load lands, after any redirect, and only if it does.
        if isComposingNewTab || activeSession == nil {
            isComposingNewTab = false
            stampActiveTab()
            unvisitedTabIDs.insert(state.openTab(url: url).id)
            stateDidChange()
            // Its first load, once its blocking rules are in.
            activeSession?.nextLoadIsTyped = typed
        } else {
            activeSession?.nextLoadIsTyped = typed
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
        openLink(url, inBackground: inBackground, inSpace: nil, from: opener, handoff: handoff) != nil
    }

    /// `openLinkInNewTab`, in `spaceID` rather than the opener's Space when it's given (Open in Space,
    /// always in the background). Returns the new tab's ID, or nil if none was opened.
    func openLink(_ url: URL, inBackground: Bool, inSpace spaceID: UUID?, from opener: TabSession?,
                  handoff: LinkPreviewHandoff?) -> UUID? {
        guard isLoaded, Self.isWeb(url) else { return nil }
        if !inBackground {
            isComposingNewTab = false
            isSearchingTabs = false
            stampActiveTab()
        }
        // An adopted page may have redirected; the tab records where it ended up. Like any tab a link
        // opens, swiping back from its first page closes it.
        let tab = state.openTab(url: handoff?.webView.url ?? url, title: handoff?.webView.title ?? "",
                                inSpace: spaceID ?? self.spaceID(of: opener), activate: !inBackground, fromLink: true)
        unvisitedTabIDs.insert(tab.id)
        // Stamped after, so the page being read stays first in the switcher, the new tab next.
        if inBackground { stampActiveTab() }
        if let handoff {
            let session = makeSession(for: tab, adopting: handoff)
            // Visited in the preview, and recorded below: a rebuilt web view brings it back, not a visit.
            unvisitedTabIDs.remove(tab.id)
            // The page arrived in the preview, so this tab may never see it arrive. The committed one:
            // `url` may already be a page still on its way (a redirect page's target), which the tab
            // records itself if it lands.
            if let pageURL = handoff.webView.backForwardList.currentItem?.url {
                recordVisit(to: pageURL, title: handoff.webView.title ?? "", typed: false, profile: session.profileID)
                session.assumeVisited(pageURL)
            }
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
        return tab.id
    }

    // MARK: Toasts

    /// How long a toast stays up: longer with VoiceOver, which reads it first, and not at all while
    /// VoiceOver is on it (`holdToast`). UI tests keep it up until it's dismissed (no test can depend on
    /// beating a timer), unless `-uiTestingToastSeconds`.
    private static var toastLifetime: Duration? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            let seconds = UserDefaults.standard.double(forKey: "uiTestingToastSeconds")
            return seconds > 0 ? .seconds(seconds) : nil
        }
        #endif
        return UIAccessibility.isVoiceOverRunning ? .seconds(15) : .seconds(5)
    }

    /// Puts up `toast` in place of any other, and announces it to VoiceOver (queued, so a menu or sheet
    /// closing doesn't cut it off).
    func showToast(_ toast: Toast) {
        self.toast = toast
        toastsShown += 1
        let actions = toast.actions.map(\.title).joined(separator: ", ")
        let announcement = NSAttributedString(string: actions.isEmpty ? toast.spokenMessage : "\(toast.spokenMessage). \(actions).",
                                              attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
        startToastExpiry()
    }

    /// Keeps the toast up while VoiceOver is on it, so it doesn't vanish from under the user; its time
    /// starts over when VoiceOver moves off.
    func holdToast(_ held: Bool) {
        if held {
            toastExpiry?.cancel()
            toastExpiry = nil
        } else {
            startToastExpiry()
        }
    }

    private func startToastExpiry() {
        toastExpiry?.cancel()
        toastExpiry = nil
        guard let toast, let lifetime = Self.toastLifetime else { return }
        let id = toast.id
        toastExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            if !Task.isCancelled { self?.dismissToast(id) }
        }
    }

    /// A toast about a Space goes once that Space can't be switched to, or there's only one Space left:
    /// its buttons would act on a Space out of reach, and with one Space no toast names one.
    private func dismissStaleToast() {
        guard case .space(let space)? = toast?.icon else { return }
        if !hasSpacesToSwitch || state.space(space.id)?.isArchived != false { dismissToast() }
    }

    /// Takes the toast down: the one with `id`, or any.
    func dismissToast(_ id: UUID? = nil) {
        guard let toast, id == nil || toast.id == id else { return }
        self.toast = nil
        toastExpiry?.cancel()
        toastExpiry = nil
    }

    // MARK: Moves

    /// Applies `move` (a `moveTab` or `moveTabBack` of `tabID`, returning its result) and shows the
    /// result. A tab that changed profile loses its web view (`releaseSessionsOnOtherProfiles`),
    /// keeping its history and settings, so it's rebuilt, and reloads, signed in with the new
    /// profile's accounts when it's next shown. Returns the move's result: nil when nothing moved.
    @discardableResult
    func applyMove(of tabID: UUID, _ move: (inout BrowserState) -> Bool?) -> Bool? {
        guard isLoaded else { return nil }
        let spaceID = state.activeSpaceID
        guard let changesProfile = move(&state) else { return nil }
        if state.activeSpaceID != spaceID {
            isComposingNewTab = false
            isSearchingTabs = false
        }
        stateDidChange()
        return changesProfile
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
        // Where the page runs under the status bar: split off there (`PageSnapshot`).
        let band = session.webView.obscuredContentInsets.top
        let height = session.webView.bounds.height
        let tabID = session.tabID
        return Task {
            guard let image = try? await session.webView.takeSnapshot(configuration: configuration),
                  state.tabs.contains(where: { $0.id == tabID }) else { return }
            snapshots[tabID] = PageSnapshot(image, band: band, of: height)
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
        // Out of sight and earshot: no media until the tab is first shown.
        session.suspendMediaUntilShown()
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
        guard let id = state.activeTabID else { return }
        state.markViewed(tabID: id)
    }

    private func openInboxAndPending() {
        let requests: [OpenRequest]
        do {
            requests = try inbox?.drain() ?? []
        } catch {
            Logger.app.error("Shared inbox unreadable: \(error.localizedDescription, privacy: .public)")
            requests = []
        }
        let links = (requests.map { ($0.url, $0.spaceID) } + pendingURLs).filter { Self.isWeb($0.0) }
        pendingURLs.removeAll()
        guard !links.isEmpty else { return }
        isComposingNewTab = false
        isSearchingTabs = false
        // Straight to the page (default-browser rule): nothing left over it.
        showsManageSpaces = false
        spaceToEdit = nil
        closeSheetsRequest += 1
        stampActiveTab()
        // Each in the Space picked for it in the share extension, else the Focus filter's, else the one
        // last used, switching there: the page is what you came for, wherever it opens. Activating the
        // new tab switches Spaces without counting the tab left there as seen (`switchToSpace` would).
        var opened: [OpenedLink] = []
        for (url, requestedSpace) in links {
            let route = state.destinationForLink(requestedSpace: requestedSpace, focusSpace: focusFilter.spaceID)
            let tab = state.openTab(url: url, inSpace: route.spaceID, activate: false)
            state.activate(tabID: tab.id)
            unvisitedTabIDs.insert(tab.id)
            opened.append(OpenedLink(tabID: tab.id, spaceID: route.spaceID, reason: route.reason))
        }
        moveRequest = nil
        didOpenFromOtherApp(opened)
    }

    /// Build one kept a URL-less placeholder tab alive; tabs now exist only with a page, so drop any
    /// left in saved state. An empty Space is valid and shows the search panel.
    private func dropBlankTabs() {
        state.removeBlankTabs()
    }

    /// `window.open` / `target=_blank`: a new active Today tab whose web view WebKit will navigate.
    private func openChild(configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                           from opener: TabSession?) -> WKWebView? {
        // In the opener's Space: the web view WebKit hands over runs on the opener's website data. An
        // archived (or gone) Space has nowhere to put it, so the popup is refused.
        let openerSpace = spaceID(of: opener)
        guard isLoaded, openerSpace.map({ state.space($0)?.isArchived == false }) ?? true else { return nil }
        // Nor can it go where tabs use other website data than WebKit's view (an opener gone, its Space
        // since moved to another profile): it would be let go at once (`releaseSessionsOnOtherProfiles`).
        let profileID = TabSession.profileID(of: configuration.websiteDataStore)
        guard state.profile(forSpace: openerSpace ?? state.activeSpaceID).id == profileID else { return nil }
        isComposingNewTab = false
        // `window.open('')` has no URL yet; the opener navigates or writes into the new view.
        let requested = action.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
        stampActiveTab()
        let tab = state.openTab(url: requested ?? URL(string: "about:blank"), inSpace: openerSpace, fromLink: true)
        let session = makeSession(for: tab, configuration: configuration)
        // Before WebKit navigates it, so a popup from a desktop-mode tab opens in desktop mode too.
        if let opener { session.apply(opener.viewSettings) }
        session.installCachedBlocking(for: requested)
        stateDidChange()
        return session.webView
    }

    private func spaceID(of session: TabSession?) -> UUID? {
        session.flatMap { session in state.tabs.first { $0.id == session.tabID }?.spaceID }
    }

    private func stateDidChange() {
        releaseSessionsOnOtherProfiles()
        syncActiveSession()
        pruneSessions()
        dismissStaleToast()
        scheduleSave()
        writeSpacesSummary()
    }

    /// Keeps the Spaces summary the share extension and the Focus filter read in step with the state:
    /// written at once (it's small) when the Spaces you can switch to, or the active one, change. Even
    /// while saving is off after a load failure: it's a separate file, and says what the app shows.
    private func writeSpacesSummary() {
        guard isLoaded, let spacesSummary else { return }
        let summary = SpacesSummary(state)
        guard summary != writtenSummary else { return }
        do {
            try spacesSummary.write(summary)
            writtenSummary = summary
        } catch {
            Logger.app.error("Writing the Spaces summary failed: \(error.localizedDescription, privacy: .public)")
        }
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
            releaseWebView(of: evicted)
        }
    }

    /// Lets go of the tab's web view, keeping its history and view settings to rebuild it from.
    private func releaseWebView(of tabID: UUID) {
        recentTabIDs.removeAll { $0 == tabID }
        cancelBackgroundLoad(tabID, unstaging: true)
        if let session = sessions.removeValue(forKey: tabID) {
            backgroundStage.remove(session.webView)
            // Still restoring, its web view's history is empty: keep the one waiting to go in.
            if let history = session.isRestoringHistory ? session.pendingHistory : session.webView.interactionState {
                interactionStates[tabID] = history
                navigatedTabIDs.insert(tabID)
            }
            pendingViewSettings[tabID] = session.viewSettings
            session.detach()
        }
    }

    /// Lets go of every web view running on other website data than its tab's Space's profile now
    /// uses, as eviction does, keeping its back/forward history and view settings: the tab moved to a
    /// Space on another profile, its Space was switched to one, or its profile was deleted. Rebuilt
    /// from the state when next shown, it loads its page again signed in with the new profile's
    /// accounts. Decided from the state alone, so whatever changed a profile, nothing is left behind.
    /// The tab on screen goes too, its page snapshotted for its card first; `syncActiveSession`
    /// builds it again.
    private func releaseSessionsOnOtherProfiles() {
        releaseSessions { session, tab in session.profileID != state.profile(forSpace: tab.spaceID).id }
    }

    /// Lets go of the web views `shouldRelease` picks, the one on screen included, as
    /// `releaseSessionsOnOtherProfiles` does. Call `stateDidChange()` after, to build the one on
    /// screen again.
    func releaseSessions(where shouldRelease: (TabSession, Tab) -> Bool) {
        for (tabID, session) in sessions {
            guard let tab = state.tab(tabID), shouldRelease(session, tab) else { continue }
            if session === activeSession {
                // Its page as it was, for its card, before it goes.
                snapshot(session)
                session.didResignActiveTab()
                activeSession = nil
            }
            releaseWebView(of: tabID)
        }
    }

    /// Whether any live web view (a tab's, on screen or not) runs on `profileID`'s website data.
    func hasWebViews(usingProfile profileID: UUID) -> Bool {
        sessions.values.contains { $0.profileID == profileID }
    }

    /// Lets go of the web views of the Space's tabs, as eviction does, so an archived Space's pages
    /// (and any media in them) stop. Never the tab on screen.
    func releaseWebViews(inSpace spaceID: UUID) {
        for tab in state.tabs where tab.spaceID == spaceID && tab.id != state.activeTabID {
            releaseWebView(of: tab.id)
        }
    }

    private func session(for tab: Tab) -> TabSession {
        if let existing = sessions[tab.id] { return existing }
        let session = makeSession(for: tab)
        if let settings = pendingViewSettings.removeValue(forKey: tab.id) { session.apply(settings) }
        if unvisitedTabIDs.remove(tab.id) == nil { session.assumeVisited(tab.url) }
        session.start(loading: tab.url, restoring: interactionStates.removeValue(forKey: tab.id))
        return session
    }

    /// A web view for `tab` on its Space's profile: a new one, or the one WebKit's `configuration` or
    /// the link preview's `handoff` brings (on their opener's profile).
    @discardableResult
    private func makeSession(for tab: Tab, configuration: WKWebViewConfiguration? = nil,
                             adopting handoff: LinkPreviewHandoff? = nil) -> TabSession {
        let profileID = state.profile(forSpace: tab.spaceID).id
        let session = handoff.map { TabSession(tabID: tab.id, blocking: blocking, adopting: $0) }
            ?? TabSession(tabID: tab.id, profileID: profileID, blocking: blocking, configuration: configuration)
        session.activeStripColor = { [weak self] in self?.stripUIColor(for: $0) }
        let tabID = tab.id
        // History goes where the page was seen: the profile whose website data it loaded with.
        let visitProfile = session.profileID
        session.onPageChange = { [weak self] url, title in self?.pageDidChange(tabID: tabID, url: url, title: title) }
        session.onVisit = { [weak self] url, title, typed in
            self?.recordVisit(to: url, title: title, typed: typed, profile: visitProfile)
        }
        session.onTitleChange = { [weak self] url, title in
            self?.writeBrowsingHistory { await $0.updateTitle(title, for: url, profile: visitProfile) }
        }
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
        session.spacesToOpenLinksIn = { [weak self] in self?.spacesToOpenLinks(from: tabID) ?? [] }
        session.onOpenInSpace = { [weak self, weak session] url, spaceID, handoff in
            self?.openLink(url, inSpace: spaceID, from: session, handoff: handoff) ?? false
        }
        session.onClose = { [weak self] in self?.close(tabID) }
        // A web view on a deleted profile is what keeps its data store from being erased. The task
        // runs once the session's properties, the web view among them, have gone too.
        session.onRelease = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.profilesToErase.contains(visitProfile) else { return }
                self.eraseDeletedProfiles()
            }
        }
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
        unvisitedTabIDs.formIntersection(live)
        if snapshots.keys.contains(where: { !live.contains($0) }) {
            snapshots = snapshots.filter { live.contains($0.key) }
        }
        // Closing a staged tab frees its slot for the next in the queue.
        startQueuedBackgroundLoads()
    }

    private func pageDidChange(tabID: UUID, url: URL?, title: String) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if let url, url != state.tabs[index].url { navigatedTabIDs.insert(tabID) }
        state.update(tabID: tabID, url: url ?? state.tabs[index].url, title: title)
        if tabID == state.activeTabID { state.markViewed(tabID: tabID) }
        scheduleSave()
    }

    // MARK: Browsing history

    /// The default database, in Application Support (not the app group: see `BrowsingHistory`).
    /// Kept out of backups, like tab histories: it never leaves the device.
    static func openBrowsingHistory(
        at file: URL = .applicationSupportDirectory.appending(path: "History/browsing-history.sqlite")
    ) -> BrowsingHistory? {
        do {
            let history = try BrowsingHistory(fileURL: file)
            var directory = file.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            return history
        } catch {
            Logger.app.error("Browsing history unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Counts a visit in `profile`'s history; none for a profile deleted meanwhile (a page that
    /// arrived as its tab's web view was let go), whose history is being erased.
    private func recordVisit(to url: URL, title: String, typed: Bool, profile: UUID) {
        guard state.profile(profile) != nil else { return }
        let query = searchQuery(in: url)
        writeBrowsingHistory {
            await $0.recordVisit(to: url, title: title, searchQuery: query, typed: typed, profile: profile)
        }
    }

    /// The query `url` shows results for, if it's a results page of the current, a built-in, or the
    /// custom engine.
    private func searchQuery(in url: URL) -> String? {
        let engines = [settings.searchEngine] + SearchEngine.builtIn + (settings.customSearchEngine.map { [$0] } ?? [])
        return engines.lazy.compactMap { $0.query(in: url) }.first
    }

    /// Queues a write after the ones before it.
    func writeBrowsingHistory(_ write: @escaping @Sendable (BrowsingHistory) async -> Void) {
        guard let browsingHistory else { return }
        let previous = browsingHistoryChain
        browsingHistoryChain = Task {
            await previous?.value
            await write(browsingHistory)
        }
    }

    /// Runs `work` on the history after the writes queued before it, and returns its result: nil
    /// without a history database.
    func afterBrowsingHistoryWrites<Result: Sendable>(
        _ work: @escaping @Sendable (BrowsingHistory) async -> Result
    ) async -> Result? {
        guard let browsingHistory else { return nil }
        let previous = browsingHistoryChain
        let task = Task {
            await previous?.value
            return await work(browsingHistory)
        }
        browsingHistoryChain = Task { _ = await task.value }
        return await task.value
    }

    /// The icon cache is named by host: keep only sites that open tabs, the archive or history still
    /// show. After any queued history change, so a cleared site's icon goes with it.
    func forgetFavicons() {
        guard let browsingHistory else {
            favicons.forgetSites(except: state.tabs.compactMap(\.url) + state.archived.map(\.url))
            return
        }
        let previous = browsingHistoryChain
        browsingHistoryChain = Task {
            await previous?.value
            let sites = await browsingHistory.sites()
            // Tabs and archive as they are now, not as they were when this was queued.
            favicons.forgetSites(except: state.tabs.compactMap(\.url) + state.archived.map(\.url) + sites)
        }
    }

    // MARK: Saving

    /// Saving is off until the state is loaded, and while a load failure is unacknowledged.
    /// Erasing a deleted profile's data is too (`eraseDeletedProfiles`).
    var canSave: Bool { isLoaded && loadFailure == nil }

    /// Saving is allowed and the state differs from what's on disk (a fresh install with no tabs never writes).
    private var needsSave: Bool { canSave && state != lastSavedState }

    /// Debounced while the scene is active; immediate otherwise, since the process may not get another chance.
    func scheduleSave() {
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

    /// Writes the state now and returns what the file holds once every queued write has landed: nil
    /// if saving is off or a write failed. Erasing a deleted profile's data waits on this, so the
    /// deletion is on disk first and can't come back at the next launch with its data gone.
    func savedState() async -> BrowserState? {
        guard canSave else { return nil }
        saveNow()
        await saveChain?.value
        return lastSavedState
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
        writesInFlight += 1
        let save = Task { [historyStore] in
            defer { writesInFlight -= 1 }
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
        writesInFlight += 1
        let task = Task { [stateStore] in
            defer { self.writesInFlight -= 1 }
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

    #if DEBUG
    /// `-uiTestingSpaces <base URL>` (UI tests, with `-uiTesting`): adds Work, on a profile of its own
    /// ("Vialumi"), and Projects, with one tab each at `<base>/work` and `<base>/projects`, then Trip
    /// with none, unless a relaunch finds them there already. Home stays active.
    private func seedUITestingSpaces() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let base = UserDefaults.standard.string(forKey: "uiTestingSpaces").flatMap(URL.init(string:)),
              !state.spaces.contains(where: { $0.name == "Work" }) else { return }
        let vialumi = state.addProfile(name: "Vialumi", color: .indigo)
        let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo, profileID: vialumi.id)
        let projects = state.addSpace(name: "Projects", icon: .hammer, color: .orange)
        _ = state.openTab(url: base.appending(path: "work"), inSpace: work.id, activate: false)
        _ = state.openTab(url: base.appending(path: "projects"), inSpace: projects.id, activate: false)
        state.addSpace(name: "Trip", icon: .airplane, color: .green)
        // `-uiTestingExtraSpaces N`: N more, empty, for a crowded strip.
        let extra = UserDefaults.standard.integer(forKey: "uiTestingExtraSpaces")
        for n in 0..<max(0, extra) {
            state.addSpace(name: "Space \(n + 5)", icon: SpaceIcon.allCases[(n + 4) % SpaceIcon.allCases.count],
                           color: Swatch.allCases[(n + 3) % Swatch.allCases.count])
        }
    }

    /// UI tests' stand-ins for what they can't drive, under `-uiTesting` (other launches ignore them):
    /// - `cormorant://ui-testing/share?url=<url>&space=<name>`: as the share extension does with a Space
    ///   picked, appends a request for the Space of that name (none if no Space has it) to the inbox
    ///   (the test run's own), then drains it as `cormorant://open` would.
    /// - `cormorant://ui-testing/focus?space=<name>`: as the system does when a Focus with the filter
    ///   starts; no `space` (or an unknown name) as when it ends.
    /// Returns whether `url` was one of these.
    private func handleUITestingURL(_ url: URL) -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"), url.scheme == "cormorant",
              url.host() == "ui-testing" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let named = query.first { $0.name == "space" }?.value
            .flatMap { name in state.spaces.first { $0.name == name }?.id }
        switch url.path() {
        case "/share":
            guard let target = query.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) else { break }
            do {
                try inbox?.append(OpenRequest(url: target, spaceID: named))
            } catch {
                Logger.app.error("UI testing: couldn't append to the inbox: \(error.localizedDescription, privacy: .public)")
            }
            guard isLoaded else { break }
            openInboxAndPending()
            stateDidChange()
        case "/focus":
            focusFilter.set(named)
        default:
            break
        }
        return true
    }

    /// For UI tests (`UITestingProbes`): whether something the app writes while browsing isn't on
    /// disk yet: a debounced save still waiting, a write queued or running, a tab whose new page's
    /// history hasn't been queued, or a page still loading (its history is saved once it has).
    var hasUnsavedWork: Bool {
        debouncedSave != nil || writesInFlight > 0 || !navigatedTabIDs.isEmpty
            || sessions.values.contains { $0.isLoading }
    }
    #endif

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
