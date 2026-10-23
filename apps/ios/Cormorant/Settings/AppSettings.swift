import CormorantCore
import Observation

/// User settings outside blocking. Persisted in the app-group defaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let searchEngine = "searchEngine"
        static let customSearchEngine = "customSearchEngine"
    }

    static let customEngineID = "custom"

    var searchEngine: SearchEngine {
        didSet { AppGroupStorage.save(searchEngine, key: Key.searchEngine) }
    }

    /// The user's own engine, remembered even while a built-in one is selected.
    var customSearchEngine: SearchEngine? {
        didSet { AppGroupStorage.save(customSearchEngine, key: Key.customSearchEngine) }
    }

    init() {
        searchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.searchEngine) ?? .default
        customSearchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.customSearchEngine)
    }
}
