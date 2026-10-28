import Foundation
import OSLog

/// Each tab's back/forward history (WebKit's opaque `interactionState`), one file per tab, so it
/// survives a relaunch. Kept out of `BrowserState`: it can be large, and the share extension has
/// no use for it. Best effort throughout: a lost or unreadable file only costs that tab its history.
/// Not backed up: entries can carry form contents.
actor TabHistoryStore {
    let directory: URL

    init(directory: URL = .applicationSupportDirectory.appending(path: "TabHistory", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    /// The saved history of each of `tabIDs`. Files for any other tab are deleted.
    func load(keeping tabIDs: Set<UUID>) -> [UUID: Data] {
        var histories: [UUID: Data] = [:]
        for file in files() {
            guard let tabID = tabID(of: file), tabIDs.contains(tabID) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            histories[tabID] = try? Data(contentsOf: file)
        }
        return histories
    }

    /// Writes `changed` and deletes the files of tabs not in `live`. Returns the tabs whose history
    /// couldn't be written.
    func save(_ changed: [UUID: Data], live: Set<UUID>) -> Set<UUID> {
        var failed: Set<UUID> = []
        if !changed.isEmpty {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var directory = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
            } catch {
                Logger.app.error("Couldn't create the tab history folder: \(error.localizedDescription, privacy: .public)")
                return Set(changed.keys)
            }
        }
        for (tabID, history) in changed {
            do {
                try history.write(to: file(for: tabID), options: .atomic)
            } catch {
                Logger.app.error("Saving a tab's history failed: \(error.localizedDescription, privacy: .public)")
                failed.insert(tabID)
            }
        }
        for file in files() where tabID(of: file).map(live.contains) != true {
            try? FileManager.default.removeItem(at: file)
        }
        return failed
    }

    private func file(for tabID: UUID) -> URL {
        directory.appending(path: "\(tabID.uuidString).history")
    }

    private func tabID(of file: URL) -> UUID? {
        UUID(uuidString: file.deletingPathExtension().lastPathComponent)
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
