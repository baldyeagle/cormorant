import CormorantCore
import SwiftUI

@main
struct CormorantApp: App {
    @State private var store = Self.makeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserView()
                #if DEBUG
                .overlay(alignment: .topLeading) { if Self.isUITesting { UITestingProbes() } }
                #endif
                .environment(store)
                .task { await store.launch() }
                .onOpenURL { store.handle(openURL: $0) }
                #if DEBUG
                .preferredColorScheme(Self.forcedColorScheme)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.didBecomeActive()
            case .inactive: store.didBecomeInactive()
            case .background: store.didEnterBackground()
            @unknown default: break
            }
        }
    }

    #if DEBUG
    private static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

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
        // `-uiTesting` launch argument (CormorantUITests): tabs, their history and icons are saved to
        // throwaway files instead of the app group's, settings to a throwaway defaults suite, the share
        // extension's inbox is left alone, and no filter lists are downloaded, compiled or installed.
        // Each launch starts with no tabs, no icons and default settings, unless
        // `CORMORANT_UI_TESTING_SESSION=<name>` in the environment names files to reuse (relaunch tests).
        if isUITesting {
            let session = ProcessInfo.processInfo.environment["CORMORANT_UI_TESTING_SESSION"]
            let run = URL.temporaryDirectory.appending(path: "ui-testing-\(session ?? UUID().uuidString)")
            // Per named session too, so a test that leaves a setting changed can't reach another's relaunch.
            let suite = "dev.baldyeagle.cormorant.ui-testing" + (session.map { ".\($0)" } ?? "")
            if session == nil { UserDefaults.standard.removePersistentDomain(forName: suite) }
            return BrowserStore(
                stateStore: JSONBrowserStateStore(fileURL: run.appendingPathExtension("json")),
                historyStore: TabHistoryStore(directory: run.appending(path: "History")),
                blocking: BlockingService(usesFilterLists: false),
                settings: AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard),
                favicons: FaviconStore(directory: run.appending(path: "Favicons")),
                receivesSharedLinks: false
            )
        }
        #endif
        return BrowserStore()
    }
}
