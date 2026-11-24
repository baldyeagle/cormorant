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
        .windowStyle(.hiddenTitleBar)
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

/// What the menu bar and the window share.
@Observable
final class WindowCommands {
    /// The command bar is up editing this tab's address.
    var isEditingAddress = false
    var isFinding = false
    /// Find Next and Previous (`backwards`), or nil to put the cursor back in the find field.
    var findRequest = FindRequest(backwards: nil)

    struct FindRequest: Equatable {
        let id = UUID()
        let backwards: Bool?
    }
    var showsSidebar = UserDefaults.standard.object(forKey: "showsSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: "showsSidebar") }
    }
    var sidebarWidth = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 264 {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
    }

    /// With no tab there's no address to edit: a new tab's instead.
    func editAddress(in store: BrowserStore) {
        if store.activeTab == nil {
            store.newTab()
        } else {
            store.cancelComposing()
            isEditingAddress = true
        }
    }
}

struct BrowserCommands: Commands {
    let store: BrowserStore
    let commands: WindowCommands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Again, puts the bar away.
            Button("New Tab") {
                if store.isComposingNewTab { store.cancelComposing() } else { store.newTab() }
            }
            .keyboardShortcut("t")
            Button("Reopen Closed Tab") { store.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Open Location") {
                if commands.isEditingAddress { commands.isEditingAddress = false } else { commands.editAddress(in: store) }
            }
            .keyboardShortcut("l")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Link") {
                guard let url = store.activeTab?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                commands.isEditingAddress = false
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste and Go") {
                guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
                store.submit(pasted)
                commands.isEditingAddress = false
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                if commands.isFinding { commands.findRequest = .init(backwards: nil) } else { commands.isFinding = true }
            }
            .keyboardShortcut("f")
            Button("Find Next") { find(backwards: false) }
                .keyboardShortcut("g")
            Button("Find Previous") { find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button(commands.showsSidebar ? "Hide Sidebar" : "Show Sidebar") { commands.showsSidebar.toggle() }
                .keyboardShortcut("s")
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
            Button("Reload Ignoring Cache") { shownSession?.reload(fromOrigin: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    /// The page stays on screen under ⌘T's bar, so these act on it then too.
    private var shownSession: TabSession? { store.activeSession }

    private func find(backwards: Bool) {
        if commands.isFinding { commands.findRequest = .init(backwards: backwards) } else { commands.isFinding = true }
    }
}
