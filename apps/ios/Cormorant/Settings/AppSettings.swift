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
        static let tintsChrome = "tintsChromeWithSiteColors"
    }

    static let customEngineID = "custom"

    var searchEngine: SearchEngine {
        didSet { AppGroupStorage.save(searchEngine, key: Key.searchEngine, to: defaults) }
    }

    /// The user's own engine, remembered even while a built-in one is selected.
    var customSearchEngine: SearchEngine? {
        didSet { AppGroupStorage.save(customSearchEngine, key: Key.customSearchEngine, to: defaults) }
    }

    /// Tint the toolbar and status bar with the page's theme color. On by default.
    var tintsChrome: Bool {
        didSet { AppGroupStorage.save(tintsChrome, key: Key.tintsChrome, to: defaults) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroupStorage.defaults) {
        self.defaults = defaults
        searchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.searchEngine, from: defaults) ?? .default
        customSearchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.customSearchEngine, from: defaults)
        tintsChrome = AppGroupStorage.load(Bool.self, key: Key.tintsChrome, from: defaults) ?? true
    }
}
