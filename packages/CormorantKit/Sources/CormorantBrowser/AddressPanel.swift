import CormorantCore
import Foundation

/// What a panel for typing an address or search lists and does, whatever draws it: the iPhone's
/// search panel, the Mac's command bar.
public enum AddressPanel {
    /// History and engine results for some typed text (`text`).
    public struct Lookup: Equatable, Sendable {
        public var text = ""
        public var pages: [HistoryEntry] = []
        public var pastSearches: [String] = []
        public var engineSuggestions: [String] = []

        public init(text: String = "", pages: [HistoryEntry] = [], pastSearches: [String] = [],
                    engineSuggestions: [String] = []) {
            self.text = text
            self.pages = pages
            self.pastSearches = pastSearches
            self.engineSuggestions = engineSuggestions
        }
    }

    public struct Shown {
        /// Search Tabs only: how many tabs, and how many match.
        public var tabsHeader = ""
        /// Composing a new tab, before anything is typed: the Space's pinned tabs, as tiles.
        public var pins: [Tab] = []
        public var openTabs: [Tab] = []
        public var pages: [HistoryEntry] = []
        public var closed: [ArchivedTab] = []
        public var searches: [SearchSuggestion] = []
        /// Incognito before anything is typed: says what it keeps (nothing).
        public var incognitoNote = false

        /// Nothing to list. Search Tabs always has its line, "0 matches" included.
        public var isEmpty: Bool {
            tabsHeader.isEmpty && pins.isEmpty && openTabs.isEmpty && pages.isEmpty && closed.isEmpty && searches.isEmpty
                && !incognitoNote
        }
    }

    /// Typing pauses this long before the engine is asked, so a quick word is one request, not five.
    static let engineDelay: Duration = .milliseconds(150)

    /// What the panel lists for `query` (the typed text; nil for none), with `lookup` the latest
    /// history and engine results. Open tabs are the active Space's, or with `tabsFromEverySpace`
    /// those of every Space but archived ones and Incognito (from Incognito, only its own).
    public static func shown(for query: String?, lookup: Lookup, in store: BrowserStore,
                             tabsFromEverySpace: Bool = false) -> Shown {
        if store.isSearchingTabs {
            let search = TabSearch(tabs: store.tabs, query: query)
            return Shown(tabsHeader: search.header, openTabs: search.tabs)
        }
        // Only the typed text, searched for: no history, tabs or suggestions.
        if store.searchesPrivately {
            guard let query else { return Shown(incognitoNote: true) }
            return Shown(searches: AddressSuggestions(text: query, engine: store.settings.searchEngine, openTabs: [], archived: [],
                                                      pages: [], pastSearches: [], engineSuggestions: []).searches)
        }
        let tabs = tabsFromEverySpace ? tabsOfEverySpace(in: store) : store.tabs
        let candidates = AddressSuggestions.openTabCandidates(tabs, activeTabID: store.state.activeTabID,
                                                              composingNewTab: store.isComposingNewTab)
        let closed = store.state.archived(reopeningIn: store.state.activeSpaceID)
        guard let query else {
            // Most recently closed first.
            let recentlyClosed = closed.sorted { $0.archivedAt > $1.archivedAt }
            // A new tab's panel starts with the Space's pins, which then aren't listed again as open tabs.
            let pins = store.isComposingNewTab || store.activeTab == nil ? store.pinnedTabs : []
            let openTabs = candidates.filter { tab in !pins.contains { $0.id == tab.id } }
            return Shown(pins: pins, openTabs: Array(openTabs.prefix(rowLimit)), closed: Array(recentlyClosed.prefix(rowLimit)))
        }
        // Until this query's own results arrive, the last ones that still fit it stand in, so rows
        // don't blink out and back on every key.
        let current = lookup.text == query
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let suggestions = AddressSuggestions(
            text: query,
            engine: store.settings.searchEngine,
            openTabs: candidates,
            archived: closed,
            pages: current ? lookup.pages
                : lookup.pages.filter { AddressSuggestions.matches(query, title: $0.title, url: $0.url) },
            pastSearches: current ? lookup.pastSearches
                : lookup.pastSearches.filter { search in words.allSatisfy { search.lowercased().contains($0) } },
            engineSuggestions: current ? lookup.engineSuggestions
                : lookup.engineSuggestions.filter { $0.lowercased().hasPrefix(query.lowercased()) }
        )
        return Shown(openTabs: suggestions.openTabs, pages: suggestions.pages,
                     closed: suggestions.closed, searches: suggestions.searches)
    }

    /// History matches for `query` at once, then (for a search, not an address) the engine's
    /// suggestions after a pause, each handed to `update`. `previous` is what's shown now, whose
    /// engine suggestions that still fit stay until new ones come. Stops when its task is cancelled,
    /// as it is by the next key.
    public static func lookUp(_ query: String, after previous: Lookup, in store: BrowserStore,
                              update: (Lookup) -> Void) async {
        var found = await historyLookup(for: query, in: store)
        guard !Task.isCancelled else { return }
        found.engineSuggestions = previous.engineSuggestions.filter { $0.lowercased().hasPrefix(query.lowercased()) }
        update(found)

        let engine = store.settings.searchEngine
        guard store.settings.searchSuggestions, let client = store.searchSuggestions, engine.offersSuggestions,
              SearchSuggestionClient.mayAsk(about: query, engine: engine) else {
            found.engineSuggestions = []
            update(found)
            return
        }
        try? await Task.sleep(for: engineDelay)
        guard !Task.isCancelled else { return }
        found.engineSuggestions = await client.suggestions(for: query, from: engine)
        guard !Task.isCancelled else { return }
        update(found)
    }

    /// History's pages and earlier searches matching `query`, in the active Space's profile: a lookup
    /// without the engine's suggestions.
    public static func historyLookup(for query: String, in store: BrowserStore) async -> Lookup {
        let history = store.browsingHistory, profile = store.activeProfileID
        let pages = await history?.pages(matching: query, profile: profile) ?? []
        let pastSearches = await history?.searches(matching: query, profile: profile) ?? []
        return Lookup(text: query, pages: pages, pastSearches: pastSearches)
    }

    /// The open tab already on the page `url` (as history matches pages: no scheme, `www.` or trailing
    /// slash), to switch to rather than open it again. Not the tab whose address is being edited.
    public static func openTab(on url: URL, in store: BrowserStore, tabsFromEverySpace: Bool = false) -> Tab? {
        guard let key = BrowsingHistory.key(for: url) else { return nil }
        let tabs = tabsFromEverySpace ? tabsOfEverySpace(in: store) : store.tabs
        return AddressSuggestions.openTabCandidates(tabs, activeTabID: store.state.activeTabID,
                                                    composingNewTab: store.isComposingNewTab)
            .first { $0.url.flatMap(BrowsingHistory.key(for:)) == key }
    }

    /// Return with `text` in the field, the panel listing `shown`.
    public static func submit(_ text: String, shown: Shown, in store: BrowserStore) {
        if store.isSearchingTabs {
            // The best match; with none, the text is searched for in a new tab instead.
            if let tab = shown.openTabs.first {
                if tab.id != store.state.activeTabID { store.activate(tab.id) }
            } else {
                store.submit(text, inNewTab: true)
            }
        } else {
            store.submit(text)
        }
    }

    private static let rowLimit = 6

    /// The tabs of every Space but archived ones (choosing one would bring its Space back),
    /// most recently viewed first; from Incognito, only its own.
    private static func tabsOfEverySpace(in store: BrowserStore) -> [Tab] {
        let inIncognito = store.state.activeSpaceID == Space.incognitoID
        return store.state.tabs
            .filter { $0.isIncognito == inIncognito && store.state.space($0.spaceID)?.isArchived != true }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
    }
}
