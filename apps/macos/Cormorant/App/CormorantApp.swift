import AppKit
import CormorantBrowser
import CormorantCore
import SwiftUI

@main
struct CormorantApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var commands = WindowCommands()

    var body: some Scene {
        Window("Cormorant", id: "browser") {
            BrowserWindow(store: delegate.store, commands: commands)
                .task { await delegate.store.launch() }
                .onOpenURL { delegate.store.handle(openURL: $0) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands(store: delegate.store, commands: commands) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let platform = MacBrowserPlatform()
    private(set) lazy var store = makeStore()

    /// The store isn't told when the app goes inactive: a Mac app keeps running behind others, and
    /// the store saves on its own until it quits.
    func applicationDidBecomeActive(_ notification: Notification) {
        store.didBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.didEnterBackground()
        Task {
            await platform.finishRunning()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Everything the engine would keep in the app group (the saved state, blocking's lists and
    /// preferences, settings) is given a place of its own: there's no app group, and on a Mac the
    /// group's folder is found even without one, then can't be written. The other default folders are
    /// the sandbox container's.
    private func makeStore() -> BrowserStore {
        BrowserStore(
            stateStore: JSONBrowserStateStore(fileURL: .applicationSupportDirectory.appending(path: "browser-state.json")),
            blocking: BlockingService(cacheDirectory: .cachesDirectory.appending(path: "Blocking", directoryHint: .isDirectory),
                                      defaults: .standard),
            settings: AppSettings(defaults: .standard),
            focusFilter: FocusFilterSettings(defaults: .standard, systemFilterSpace: nil),
            inbox: nil,
            spacesSummary: nil,
            // Passes, calendar files and models open from Finder like any download.
            downloads: DownloadCenter(handoffs: []),
            platform: platform
        )
    }
}

/// What the menu bar asks of the window.
@Observable
final class WindowCommands {
    var addressFocusRequest = 0
}

struct BrowserCommands: Commands {
    let store: BrowserStore
    let commands: WindowCommands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }
                .keyboardShortcut("t")
            Button("Open Location") { commands.addressFocusRequest += 1 }
                .keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if store.isComposingNewTab {
                    store.cancelComposing()
                } else if let id = store.state.activeTabID {
                    store.close(id)
                }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Page") {
            Button("Back") { shownSession?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { shownSession?.goForward() }
                .keyboardShortcut("]")
            Button("Reload") { shownSession?.reload() }
                .keyboardShortcut("r")
        }
    }

    private var shownSession: TabSession? { store.isComposingNewTab ? nil : store.activeSession }
}
