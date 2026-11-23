import WebKit

/// Incognito's website data: one store kept in memory only (`WKWebsiteDataStore.nonPersistent()`),
/// shared by every Incognito tab, so a site signed in to in one is signed in to in the next, and in a
/// popup it opens. Made when the first Incognito web view needs it; `end()` lets it go once the last
/// Incognito tab has closed, and the next Incognito tab starts with nothing.
@MainActor
enum IncognitoData {
    private static var current: WKWebsiteDataStore?

    static var store: WKWebsiteDataStore {
        if let current { return current }
        let store = WKWebsiteDataStore.nonPersistent()
        current = store
        return store
    }

    /// Lets go of the store. WebKit drops what's in it once no web view uses it either; it's emptied
    /// first, so nothing a closing page or the network process still holds outlives it.
    static func end() {
        guard let store = current else { return }
        current = nil
        Task { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
    }

    #if DEBUG
    /// For tests: whether a store is held.
    static var isActive: Bool { current != nil }
    #endif
}
