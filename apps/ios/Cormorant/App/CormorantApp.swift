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
        // `-uiTesting` launch argument (CormorantUITests): tabs, their history and icons are saved to
        // throwaway files instead of the app group's, and the share extension's inbox is left alone.
        // Each launch starts with no tabs and no icons, unless `CORMORANT_UI_TESTING_SESSION=<name>` in
        // the environment names files to reuse (relaunch tests).
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            let session = ProcessInfo.processInfo.environment["CORMORANT_UI_TESTING_SESSION"]
            let run = URL.temporaryDirectory.appending(path: "ui-testing-\(session ?? UUID().uuidString)")
            return BrowserStore(
                stateStore: JSONBrowserStateStore(fileURL: run.appendingPathExtension("json")),
                historyStore: TabHistoryStore(directory: run.appending(path: "History")),
                favicons: FaviconStore(directory: run.appending(path: "Favicons")),
                receivesSharedLinks: false
            )
        }
        #endif
        return BrowserStore()
    }
}
