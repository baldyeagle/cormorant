import Foundation

/// A query the address field offers to search for.
public struct SearchSuggestion: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// What the user typed.
        case typed
        /// Searched for before (`BrowsingHistory.searches(matching:)`).
        case history
        /// The search engine's own suggestion.
        case engine
    }

    public let query: String
    public let source: Source

    public init(query: String, source: Source) {
        self.query = query
        self.source = source
    }
}

/// What the search panel lists for some typed text, by section, best first within each:
/// open tabs to switch to, pages from history, recently closed tabs, then searches.
/// The same page never appears twice: an open tab hides its history entry, and a history entry
/// hides its closed tab.
public struct AddressSuggestions: Equatable, Sendable {
    public struct Limits: Equatable, Sendable {
        public var openTabs: Int
        public var pages: Int
        public var closed: Int
        /// Including the typed query's own row.
        public var searches: Int
        /// Past searches kept when the engine has suggestions too, so both get a say.
        public var pastSearchesBesideEngine: Int

        public init(openTabs: Int, pages: Int, closed: Int, searches: Int, pastSearchesBesideEngine: Int) {
            self.openTabs = openTabs
            self.pages = pages
            self.closed = closed
            self.searches = searches
            self.pastSearchesBesideEngine = pastSearchesBesideEngine
        }

        public static let standard = Limits(openTabs: 3, pages: 4, closed: 2, searches: 9, pastSearchesBesideEngine: 2)
    }

    public var openTabs: [Tab] = []
    public var pages: [HistoryEntry] = []
    public var closed: [ArchivedTab] = []
    public var searches: [SearchSuggestion] = []

    public var isEmpty: Bool { openTabs.isEmpty && pages.isEmpty && closed.isEmpty && searches.isEmpty }

    public init() {}

    /// - Parameters:
    ///   - text: what the user typed (without any inline completion).
    ///   - openTabs: candidate tabs in the order to show them; filtered here by `matches`.
    ///   - archived: every closed tab; filtered and ordered (most recently closed first) here.
    ///   - pages: history matches, best first (`BrowsingHistory.pages(matching:)`).
    ///   - pastSearches: earlier queries, best first (`BrowsingHistory.searches(matching:)`).
    ///   - engineSuggestions: the engine's suggestions, in its order.
    ///   - engine: decides whether `text` is a search (it gets the first search row) or an address.
    public init(text: String, engine: SearchEngine, openTabs: [Tab], archived: [ArchivedTab],
                pages: [HistoryEntry], pastSearches: [String], engineSuggestions: [String],
                limits: Limits = .standard) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.openTabs = Array(openTabs.filter { Self.matches(text, title: $0.displayTitle, url: $0.url) }
            .prefix(limits.openTabs))
        let openKeys = Set(openTabs.compactMap { $0.url.flatMap(BrowsingHistory.key(for:)) })

        self.pages = Array(pages.filter { !openKeys.contains($0.key) }.prefix(limits.pages))
        let shownKeys = openKeys.union(self.pages.map(\.key))

        closed = Array(archived
            .sorted { $0.archivedAt > $1.archivedAt }
            .filter { entry in
                (BrowsingHistory.key(for: entry.url).map { !shownKeys.contains($0) } ?? true)
                    && Self.matches(text, title: entry.displayTitle, url: entry.url)
            }
            .prefix(limits.closed))

        var seen: Set<String> = []
        func add(_ query: String, _ source: SearchSuggestion.Source) {
            guard searches.count < limits.searches, seen.insert(query.lowercased()).inserted else { return }
            searches.append(SearchSuggestion(query: query, source: source))
        }
        if case .search(_, let query) = AddressResolver.resolve(text, engine: engine) { add(query, .typed) }
        let past = engineSuggestions.isEmpty ? pastSearches : Array(pastSearches.prefix(limits.pastSearchesBesideEngine))
        for query in past { add(query, .history) }
        for query in engineSuggestions { add(query, .engine) }
    }

    /// Whether every word of `text` appears (ignoring case) in `title` or `url`. A leading scheme or
    /// `www.` in the first word is ignored, as `url` is compared without them.
    public static func matches(_ text: String, title: String, url: URL?) -> Bool {
        let words = BrowsingHistory.words(in: text)
        guard !words.isEmpty else { return true }
        let address = url.flatMap(BrowsingHistory.key(for:)) ?? url?.absoluteString ?? ""
        let haystack = (title + " " + address).lowercased()
        return words.allSatisfy(haystack.contains)
    }
}
