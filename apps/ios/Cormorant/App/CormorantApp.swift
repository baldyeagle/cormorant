import CormorantBrowser
import CormorantCore
import SwiftUI

@main
struct CormorantApp: App {
    @State private var store = Self.makeStore()
    @State private var defaultBrowser = Self.makeDefaultBrowser()

    init() {
        #if DEBUG
        // Before any window: at launch the keyboard comes up with the search panel, and a probe that
        // started watching later would never see it.
        if Self.isUITesting { KeyboardPresence.start() }
        if Self.isUITesting, ProcessInfo.processInfo.arguments.contains("-uiTestingShowTouches") { TouchMarks.start() }
        #endif
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if Self.isHostingTests {
                // CormorantTests build their own stores and windows; this one stays empty and unloaded.
                Color.clear
            } else {
                browser
            }
            #else
            browser
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            if Self.isHostingTests { return }
            #endif
            switch phase {
            case .active:
                defaultBrowser.didBecomeActive()
                store.didBecomeActive()
            case .inactive: store.didBecomeInactive()
            case .background: store.didEnterBackground()
            @unknown default: break
            }
        }
    }

    private var browser: some View {
        BrowserView()
            #if DEBUG
            .overlay(alignment: .topLeading) { if Self.isUITesting { UITestingProbes() } }
            #endif
            .environment(store)
            .environment(defaultBrowser)
            .task { await store.launch() }
            .onOpenURL { url in
                if ["http", "https"].contains(url.scheme?.lowercased()) { defaultBrowser.didReceiveWebURL() }
                store.handle(openURL: url)
            }
            #if DEBUG
            .preferredColorScheme(Self.forcedColorScheme)
            #endif
    }

    #if DEBUG
    private static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    /// The app is the host of the in-process tests (CormorantTests): XCTest sets these for the app it
    /// injects a test bundle into (which one depends on the Xcode), never for one a UI test launches.
    /// CormorantTests' `TestHostTests` fails if none is set, rather than let the tests run beside a
    /// live browser.
    static let isHostingTests = !isUITesting
        && ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { ProcessInfo.processInfo.environment[$0] != nil }

    /// `-uiTestingAppearance dark|light` (CormorantUITests): `XCUIDevice.appearance` doesn't take on
    /// the iOS 27 simulator, so tests pick the app's appearance (pages' `prefers-color-scheme` too) here.
    private static var forcedColorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "uiTestingAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }
    #endif

    private static func makeStore() -> BrowserStore {
        #if DEBUG
        // Hosting CormorantTests: a store that's never launched, on throwaway files, so nothing the
        // tests do reaches the app group or the system.
        if isHostingTests {
            let run = URL.temporaryDirectory.appending(path: "test-host-\(UUID().uuidString)")
            let defaults = UserDefaults(suiteName: "dev.baldyeagle.cormorant.test-host") ?? .standard
            return BrowserStore(
                stateStore: JSONBrowserStateStore(fileURL: run.appendingPathExtension("json")),
                historyStore: TabHistoryStore(directory: run.appending(path: "History")),
                blocking: BlockingService(usesFilterLists: false),
                settings: AppSettings(defaults: defaults),
                favicons: FaviconStore(directory: run.appending(path: "Favicons")),
                browsingHistory: nil,
                searchSuggestions: nil,
                focusFilter: FocusFilterSettings(defaults: defaults, systemFilterSpace: nil),
                inbox: nil,
                spacesSummary: nil,
                platform: IOSBrowserPlatform()
            )
        }
        // `-uiTesting` launch argument (CormorantUITests): tabs, their history and icons are saved to
        // throwaway files instead of the app group's, settings (the Focus filter's Space too, which
        // tests set themselves) to a throwaway defaults suite, the share extension's inbox and Spaces
        // summary are the run's own, no filter lists are downloaded, compiled or installed, downloads
        // go to the run's own folder, the default-browser status never asks the system (it answers
        // only a few times a year), and search engines aren't asked for suggestions unless
        // `-uiTestingSearchSuggestions` says to.
        // Each launch starts with no tabs, no icons and default settings, unless
        // `CORMORANT_UI_TESTING_SESSION=<name>` in the environment names files to reuse (relaunch tests).
        if isUITesting {
            let session = ProcessInfo.processInfo.environment["CORMORANT_UI_TESTING_SESSION"]
            let run = URL.temporaryDirectory.appending(path: "ui-testing-\(session ?? UUID().uuidString)")
            // Per named session too, so a test that leaves a setting changed can't reach another's relaunch.
            let suite = "dev.baldyeagle.cormorant.ui-testing" + (session.map { ".\($0)" } ?? "")
            if session == nil { UserDefaults.standard.removePersistentDomain(forName: suite) }
            PageFileShare.cache = SharedFileCache(directory: run.appending(path: "Shared Files"))
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            let settings = AppSettings(defaults: defaults)
            // `-uiTestingSearchEngine <template>`: searches go to the test's FixtureServer, not the network.
            if let template = UserDefaults.standard.string(forKey: "uiTestingSearchEngine") {
                settings.searchEngine = SearchEngine(id: AppSettings.customEngineID, name: "Fixture", queryTemplate: template)
            }
            return BrowserStore(
                stateStore: JSONBrowserStateStore(fileURL: run.appendingPathExtension("json")),
                historyStore: TabHistoryStore(directory: run.appending(path: "History")),
                blocking: BlockingService(usesFilterLists: false),
                settings: settings,
                favicons: FaviconStore(directory: run.appending(path: "Favicons")),
                browsingHistory: BrowserStore.openBrowsingHistory(at: run.appending(path: "browsing-history.sqlite")),
                searchSuggestions: ProcessInfo.processInfo.arguments.contains("-uiTestingSearchSuggestions") ? SearchSuggestionClient() : nil,
                focusFilter: FocusFilterSettings(defaults: defaults, systemFilterSpace: nil),
                inbox: SharedInbox(fileURL: run.appending(path: "inbox.json")),
                spacesSummary: SpacesSummaryFile(fileURL: run.appending(path: "spaces-summary.json")),
                downloads: DownloadCenter(directory: run.appending(path: "Downloads")),
                platform: IOSBrowserPlatform()
            )
        }
        #endif
        // Shares the app didn't live to finish, and files whose copies were good for the last launch only.
        PageFileShare.cache.pruneAtLaunch()
        return BrowserStore(focusFilter: .shared, platform: IOSBrowserPlatform())
    }

    private static func makeDefaultBrowser() -> DefaultBrowserStatus {
        #if DEBUG
        if isUITesting || isHostingTests { return DefaultBrowserStatus(isLive: false) }
        #endif
        return DefaultBrowserStatus()
    }
}
