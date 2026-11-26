import CormorantCore
import Foundation
import Observation

/// User settings outside blocking. Persisted in the app-group defaults.
@MainActor
@Observable
public final class AppSettings {
    private enum Key {
        static let searchEngine = "searchEngine"
        static let customSearchEngine = "customSearchEngine"
        static let pageUnderStatusBar = "pageUnderStatusBar"
        static let searchSuggestions = "searchSuggestions"
        static let incognitoIcon = "incognitoIcon"
        static let syncsWithICloud = "syncsWithICloud"
    }

    public static let customEngineID = "custom"

    public var searchEngine: SearchEngine {
        didSet { AppGroupStorage.save(searchEngine, key: Key.searchEngine, to: defaults) }
    }

    /// The user's own engine, remembered even while a built-in one is selected.
    public var customSearchEngine: SearchEngine? {
        didSet { AppGroupStorage.save(customSearchEngine, key: Key.customSearchEngine, to: defaults) }
    }

    /// The page runs up under the status bar, which takes its style from the page; off, the status
    /// bar sits on the default strip. On by default.
    public var pageUnderStatusBar: Bool {
        didSet { AppGroupStorage.save(pageUnderStatusBar, key: Key.pageUnderStatusBar, to: defaults) }
    }

    /// While typing a search, ask the search engine what to suggest (it sees each keystroke). Only
    /// for engines that offer suggestions, and never for text that's an address. On by default.
    public var searchSuggestions: Bool {
        didSet { AppGroupStorage.save(searchSuggestions, key: Key.searchSuggestions, to: defaults) }
    }

    /// The sunglasses Incognito shows (Settings › Appearance). Wayfarer by default.
    public var incognitoIcon: IncognitoIcon {
        didSet { AppGroupStorage.save(incognitoIcon, key: Key.incognitoIcon, to: defaults) }
    }

    /// Spaces, tabs and the tab archive are kept the same on every device signed into the same iCloud
    /// account, end to end encrypted. Off by default. Change it through `BrowserStore.setSync(on:)`,
    /// which also starts and stops it.
    public var syncsWithICloud: Bool {
        didSet { AppGroupStorage.save(syncsWithICloud, key: Key.syncsWithICloud, to: defaults) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppGroupStorage.defaults) {
        self.defaults = defaults
        searchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.searchEngine, from: defaults) ?? .default
        customSearchEngine = AppGroupStorage.load(SearchEngine.self, key: Key.customSearchEngine, from: defaults)
        pageUnderStatusBar = AppGroupStorage.load(Bool.self, key: Key.pageUnderStatusBar, from: defaults) ?? true
        searchSuggestions = AppGroupStorage.load(Bool.self, key: Key.searchSuggestions, from: defaults) ?? true
        incognitoIcon = AppGroupStorage.load(IncognitoIcon.self, key: Key.incognitoIcon, from: defaults) ?? .default
        syncsWithICloud = AppGroupStorage.load(Bool.self, key: Key.syncsWithICloud, from: defaults) ?? false
    }
}
