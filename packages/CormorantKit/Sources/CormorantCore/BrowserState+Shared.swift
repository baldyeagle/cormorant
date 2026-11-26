import Foundation

// MARK: - What sync shares
//
// The part of the state every device holds the same: Spaces, profiles (their names, not their website
// data), open tabs, their folders and the tab archive. Which Space and tab are in front stays each device's own, and
// so do Incognito's tabs and blank tabs (a new tab nothing was loaded in yet).

extension BrowserState {
    public struct Shared: Equatable, Sendable {
        /// In display order.
        public var spaces: [Space]
        public var profiles: [Profile]
        /// In `BrowserState.tabs` order. No Incognito tab and no blank one.
        public var tabs: [Tab]
        /// The folders `tabs` are in, oldest first (`Shared.sorted`): a folder has no place of its own,
        /// so no order to keep. Not one that only blank tabs are in: no other device would have a tab in it.
        public var folders: [Folder]
        public var archived: [ArchivedTab]

        public init(spaces: [Space] = [], profiles: [Profile] = [], tabs: [Tab] = [], folders: [Folder] = [],
                    archived: [ArchivedTab] = []) {
            self.spaces = spaces
            self.profiles = profiles
            self.tabs = tabs
            self.folders = Self.sorted(folders)
            self.archived = archived
        }

        /// The one order folders are compared in, on every device.
        public static func sorted(_ folders: [Folder]) -> [Folder] {
            folders.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        }
    }

    /// Whether sync shares the tab: not Incognito's, and not blank.
    public static func isShared(_ tab: Tab) -> Bool { !tab.isIncognito && tab.url != nil }

    public var shared: Shared {
        let shared = tabs.filter(Self.isShared)
        let used = Set(shared.compactMap(\.folderID))
        return Shared(spaces: spaces, profiles: profiles, tabs: shared, folders: folders.filter { used.contains($0.id) },
                      archived: archived)
    }

    /// Replaces the shared part, as merged with another device's. Incognito's tabs and blank tabs stay,
    /// after the shared ones, and so does a folder only they are in. A folder none of the tabs is in
    /// goes, as always (`pruneFolders`). A profile that's gone is erased here as if deleted here
    /// (`profilesToErase`). The active Space and tab stay if they still exist; when the active tab is
    /// gone, the Space's most recently viewed one takes its place.
    public mutating func setShared(_ shared: Shared) {
        let incoming = shared.tabs.filter(Self.isShared)
        let incomingIDs = Set(incoming.map(\.id))
        let kept = tabs.filter { !Self.isShared($0) && !incomingIDs.contains($0.id) }
        let hadActiveTab = activeTabID != nil
        let remaining = Set(shared.profiles.map(\.id))
        profilesToErase.append(contentsOf: profiles.map(\.id).filter { !remaining.contains($0) })
        spaces = shared.spaces
        profiles = shared.profiles
        tabs = incoming + kept
        let stillUsed = Set(kept.compactMap(\.folderID)).subtracting(shared.folders.map(\.id))
        folders = shared.folders + folders.filter { stillUsed.contains($0.id) }
        archived = shared.archived
        normalize()
        if hadActiveTab, activeTabID == nil { activeTabID = tabs(inSpace: activeSpaceID).first?.id }
    }
}
