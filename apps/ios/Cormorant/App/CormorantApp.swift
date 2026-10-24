import CormorantCore
import SwiftUI

@main
struct CormorantApp: App {
    @State private var store = Self.makeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserView()
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
        // `-uiTesting` launch argument (CormorantUITests): every launch starts with no tabs and default
        // app settings (blocking preferences are still the app group's), saved to a throwaway file and
        // defaults suite instead of the app group's, and leaves the share extension's inbox alone.
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            let file = URL.temporaryDirectory.appending(path: "ui-testing-\(UUID().uuidString).json")
            let suite = "dev.baldyeagle.cormorant.ui-testing"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            return BrowserStore(stateStore: JSONBrowserStateStore(fileURL: file),
                                settings: AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard),
                                receivesSharedLinks: false)
        }
        #endif
        return BrowserStore()
    }
}
