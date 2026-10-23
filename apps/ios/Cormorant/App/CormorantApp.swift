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

    private static func makeStore() -> BrowserStore {
        #if DEBUG
        // `-uiTesting` launch argument (CormorantUITests): every launch starts with no tabs, saved to a
        // throwaway file instead of the app group's, and leaves the share extension's inbox alone.
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            let file = URL.temporaryDirectory.appending(path: "ui-testing-\(UUID().uuidString).json")
            return BrowserStore(stateStore: JSONBrowserStateStore(fileURL: file), receivesSharedLinks: false)
        }
        #endif
        return BrowserStore()
    }
}
