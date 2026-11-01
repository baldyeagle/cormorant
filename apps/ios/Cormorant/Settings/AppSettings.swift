import CormorantCore
import Foundation
import Observation

/// User settings outside blocking. Persisted in the app-group defaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let searchEngine = "searchEngine"
        static let customSearchEngine = "customSearchEngine"
        static let pageUnderStatusBar = "pageUnderStatusBar"
    }

    static let customEngineID = "custom"

    var searchEngine: SearchEngine {
        didSet { AppGroupStorage.save(searchEngine, key: Key.searchEngine, to: defaults) }
    }

    /// The user's own engine, remembered even while a built-in one is selected.
    var customSearchEngine: SearchEngine? {
        didSet { AppGroupStorage.save(customSearchEngine, key: Key.customSearchEngine, to: defaults) }
    }

    /// The page runs up under the status bar, which takes its style from the page; off, the status
    /// bar sits on the default strip. On by default.
    var pageUnderStatusBar: Bool {
        didSet { AppGroupStorage.save(pageUnderStatusBar, key: Key.pageUnderStatusBar, to: defaults) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroupStorage.defaults) {
        self.defaults = defaults
        searchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.searchEngine, from: defaults) ?? .default
        customSearchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.customSearchEngine, from: defaults)
        pageUnderStatusBar = AppGroupStorage.load(Bool.self, key: Key.pageUnderStatusBar, from: defaults) ?? true
    }
}
