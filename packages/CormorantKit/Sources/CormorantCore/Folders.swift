import Foundation

// MARK: - Folders, tiles and the pinned list
//
// A Space's pins show as tiles (`PinPlace.tile`) or as rows of its pinned list (`.list`). A folder
// holds tabs of one kind: a pinned folder is in the pinned list and holds list pins; any other is
// among the Space's other tabs and holds those. Tiles are never in a folder.
//
// A folder has no place of its own: it shows where its first tab is, in the order its section keeps
// (pins: `tabs` order; other tabs: `listedTabs` or `unpinnedTabs` order), with all its tabs under it
// in that order. So a folder always holds a tab, and one left empty goes (`pruneFolders`).

/// Where a pinned tab shows.
public enum PinPlace: String, Hashable, Codable, Sendable {
    /// A tile: on the Mac, the grid above the pinned list; on the iPhone, the row of tiles.
    case tile
    /// A row of the pinned list, which folders can join. On the iPhone, a tile after the tiles.
    case list

    /// Unknown raw values (a newer build's) decode as `.tile`.
    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PinPlace.init(rawValue:)) ?? .tile
    }
}

/// A named group of a Space's tabs, all pinned or all not (see the top of this file).
public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    public var name: String
    /// The SF Symbol drawn on the folder, one of `Folder.icons`; nil for a plain folder.
    public var icon: String?
    /// Showing its tabs where a list shows folders open or closed (the Mac's sidebar).
    public var isOpen: Bool
    public let createdAt: Date

    public init(id: UUID = UUID(), spaceID: UUID, name: String, icon: String? = nil, isOpen: Bool = true,
                createdAt: Date = .now) {
        self.id = id
        self.spaceID = spaceID
        self.name = name
        self.icon = icon
        self.isOpen = isOpen
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            spaceID: try container.decodeIfPresent(UUID.self, forKey: .spaceID) ?? Space.defaultID,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            icon: try? container.decodeIfPresent(String.self, forKey: .icon),
            isOpen: (try? container.decodeIfPresent(Bool.self, forKey: .isOpen)) ?? true,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        )
    }

    /// What a folder is called when it's made, until renamed.
    public static let defaultName = "New Folder"

    /// The symbols a folder's Icon picker offers, in order.
    public static let icons = [
        "star.fill", "bookmark.fill", "heart.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill", "lightbulb.fill",
        "bubble.left.fill", "person.2.fill", "hammer.fill", "drop.fill", "circle.fill", "moon.fill", "globe.americas.fill", "leaf.fill",
        "cloud.fill", "pawprint.fill", "fork.knife", "airplane", "music.note", "video.fill",
        "chevron.left.forwardslash.chevron.right", "book.fill",
    ]
}

/// A folder as its tabs remember it in the archive, to bring it back with them.
public struct ArchivedFolder: Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let icon: String?

    public init(id: UUID, name: String, icon: String?) {
        self.id = id
        self.name = name
        self.icon = icon
    }

    init(_ folder: Folder) { self.init(id: folder.id, name: folder.name, icon: folder.icon) }
}

/// What `closeFolder` closed, for its Undo (`undoCloseFolder`).
public struct ClosedFolder: Sendable {
    let folder: Folder
    /// Each with its index in `tabs` as it closed, in that order.
    let tabs: [(index: Int, tab: Tab)]
    let activeTabID: UUID?
}

/// One entry of a list of a Space's tabs: a tab, or a folder with its tabs.
public enum SidebarItem: Identifiable, Hashable, Sendable {
    case tab(Tab)
    case folder(Folder, tabs: [Tab])

    public var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .folder(let folder, _): folder.id
        }
    }

    /// Every tab in it: the one, or the folder's.
    public var tabs: [Tab] {
        switch self {
        case .tab(let tab): [tab]
        case .folder(_, let tabs): tabs
        }
    }
}

extension BrowserState {
    public func folder(_ folderID: UUID) -> Folder? { folders.first { $0.id == folderID } }

    /// The folder's tabs in the order its section keeps: pins in `tabs` order, other tabs as `listedTabs`.
    public func tabs(inFolder folderID: UUID) -> [Tab] {
        let members = tabs.filter { $0.folderID == folderID }
        return members.first?.isPinned == false ? members.reversed() : members
    }

    /// Whether the folder is in the pinned list (its tabs are pins).
    public func isPinnedFolder(_ folderID: UUID) -> Bool {
        tabs.first { $0.folderID == folderID }?.isPinned == true
    }

    /// The Space's folders that `addToFolder` can put a tab in, pinned ones first, each in its section's order.
    public func folders(inSpace spaceID: UUID) -> [Folder] {
        (pinnedList(inSpace: spaceID) + listedItems(inSpace: spaceID)).compactMap {
            if case .folder(let folder, _) = $0 { folder } else { nil }
        }
    }

    /// The Space's tile pins, in pin order.
    public func tilePins(inSpace spaceID: UUID) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned && $0.pinPlace == .tile }
    }

    /// The Space's pinned list: list pins and pinned folders, in pin order.
    public func pinnedList(inSpace spaceID: UUID) -> [SidebarItem] {
        grouped(tabs.filter { $0.spaceID == spaceID && $0.isPinned && $0.pinPlace == .list })
    }

    /// The Space's other tabs and folders, in the order a list of them keeps (`listedTabs`).
    public func listedItems(inSpace spaceID: UUID) -> [SidebarItem] {
        grouped(listedTabs(inSpace: spaceID))
    }

    /// The Space's other tabs and folders, a folder where its most recently viewed tab is
    /// (`unpinnedTabs`): the iPhone's cards.
    public func unpinnedItems(inSpace spaceID: UUID) -> [SidebarItem] {
        grouped(unpinnedTabs(inSpace: spaceID))
    }

    /// Everything pinned in the Space as one row: the tiles, then the pinned list. The iPhone's row of tiles.
    public func pinRow(inSpace spaceID: UUID) -> [SidebarItem] {
        tilePins(inSpace: spaceID).map(SidebarItem.tab) + pinnedList(inSpace: spaceID)
    }

    /// `tabs` with each folder's tabs gathered under it where the first of them is.
    private func grouped(_ tabs: [Tab]) -> [SidebarItem] {
        var items: [SidebarItem] = [], seen = Set<UUID>()
        for tab in tabs {
            guard let folderID = tab.folderID, let folder = folder(folderID) else {
                items.append(.tab(tab))
                continue
            }
            guard seen.insert(folderID).inserted else { continue }
            items.append(.folder(folder, tabs: tabs.filter { $0.folderID == folderID }))
        }
        return items
    }

    // MARK: Making and changing folders

    /// Puts the tab in a new folder, which shows where the tab was. A tile pin becomes a row of the
    /// pinned list. Returns the folder, or nil for an unknown or Incognito tab.
    @discardableResult
    public mutating func newFolder(with tabID: UUID, name: String = Folder.defaultName, now: Date = .now) -> Folder? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), !tabs[index].isIncognito else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(spaceID: tabs[index].spaceID, name: trimmed.isEmpty ? Folder.defaultName : trimmed, createdAt: now)
        folders.append(folder)
        if tabs[index].isPinned { tabs[index].pinPlace = .list }
        tabs[index].folderID = folder.id
        pruneFolders()
        return folder
    }

    /// Whether `addToFolder` would put the tab in the folder: both of one Space, the tab not Incognito
    /// and not in it already, and a tab that can be pinned if the folder is pinned.
    public func canAdd(_ tabID: UUID, toFolder folderID: UUID) -> Bool {
        guard let tab = tab(tabID), let folder = folder(folderID), tab.spaceID == folder.spaceID,
              !tab.isIncognito, tab.folderID != folderID else { return false }
        return !isPinnedFolder(folderID) || tab.isPinned || canPin(tabID)
    }

    /// Moves the tab into the folder, last in it, pinning it as a row of the pinned list if the folder
    /// is pinned, unpinning it if not. Returns whether it moved.
    @discardableResult
    public mutating func addToFolder(_ tabID: UUID, _ folderID: UUID, now: Date = .now) -> Bool {
        guard canAdd(tabID, toFolder: folderID) else { return false }
        let pinned = isPinnedFolder(folderID)
        let tab = tab(tabID)!
        if pinned, !tab.isPinned {
            pin(tabID: tabID, place: .list)
        } else if !pinned, tab.isPinned {
            unpin(tabID: tabID, now: now)
        }
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        var moving = tabs.remove(at: from)
        moving.folderID = folderID
        if moving.isPinned { moving.pinPlace = .list }
        let members = tabs.indices.filter { tabs[$0].folderID == folderID }
        // Last in the folder as its section shows it: pins in `tabs` order, other tabs the other way.
        let at = pinned ? members.last.map { $0 + 1 } : members.first
        tabs.insert(moving, at: at ?? tabs.endIndex)
        pruneFolders()
        return true
    }

    /// Takes the tab out of its folder, to just after the folder in its section.
    public mutating func removeFromFolder(_ tabID: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }), let folderID = tabs[from].folderID else { return }
        var moving = tabs.remove(at: from)
        moving.folderID = nil
        let members = tabs.indices.filter { tabs[$0].folderID == folderID }
        let at = moving.isPinned ? members.last.map { $0 + 1 } : members.first
        tabs.insert(moving, at: at ?? from)
        pruneFolders()
    }

    /// Removes the folder, leaving its tabs where they are.
    public mutating func ungroupFolder(_ folderID: UUID) {
        for index in tabs.indices where tabs[index].folderID == folderID { tabs[index].folderID = nil }
        folders.removeAll { $0.id == folderID }
    }

    /// Renames the folder. An empty name (or only spaces) leaves it as it was.
    public mutating func renameFolder(_ folderID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].name = name
    }

    /// Draws `icon` on the folder; nil for a plain folder.
    public mutating func setFolderIcon(_ folderID: UUID, _ icon: String?) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].icon = icon
    }

    public mutating func setFolderOpen(_ folderID: UUID, _ isOpen: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].isOpen = isOpen
    }

    /// Pins the folder's tabs as rows of the pinned list, the folder last in it; or unpins them, the
    /// folder first among the other tabs. Its tabs keep their order. A tab that can't be pinned (not a
    /// web page) leaves the folder.
    public mutating func moveFolder(_ folderID: UUID, toPinned pinned: Bool, now: Date = .now) {
        let members = tabs(inFolder: folderID)
        guard !members.isEmpty, isPinnedFolder(folderID) != pinned else { return }
        var moved: [Tab] = []
        for var tab in members {
            if pinned {
                guard canPin(tab.id), let url = tab.url else { continue }
                tab.kind = .pinned
                tab.pinnedURL = url
                tab.pinnedTitle = tab.title.isEmpty ? nil : tab.title
                tab.pinPlace = .list
            } else {
                tab.kind = .today
                tab.pinnedURL = nil
                tab.pinnedTitle = nil
                tab.pinPlace = .tile
                tab.lastViewedAt = max(tab.lastViewedAt, now)
            }
            moved.append(tab)
        }
        let movedIDs = Set(moved.map(\.id))
        // A tab that can't be pinned (not a web page) stays where it is, out of the folder.
        for index in tabs.indices where tabs[index].folderID == folderID && !movedIDs.contains(tabs[index].id) {
            tabs[index].folderID = nil
        }
        tabs.removeAll { movedIDs.contains($0.id) }
        // Last among the pins, in the folder's order; or first among the other tabs, which list the other way.
        tabs.append(contentsOf: pinned ? moved : moved.reversed())
        pruneFolders()
    }

    /// Closes the folder and its tabs: each is archived as a tab (pins too) with the folder, so
    /// restoring one later brings the folder back, unpinned, with them all. Returns what
    /// `undoCloseFolder` needs to put it all back as it was, or nil for an unknown folder.
    @discardableResult
    public mutating func closeFolder(_ folderID: UUID, now: Date = .now) -> ClosedFolder? {
        guard let folder = folder(folderID) else { return nil }
        let closed = ClosedFolder(folder: folder,
                                  tabs: tabs.indices.filter { tabs[$0].folderID == folderID }.map { ($0, tabs[$0]) },
                                  activeTabID: activeTabID)
        archiveTogether(closed.tabs.map(\.tab.id), folder: folder, now: now)
        return closed
    }

    /// Puts back what `closeFolder` closed, as it was: the folder, its tabs (pins still pins) in their
    /// places, and the tab that was active if it was one of them. Their archive entries go. No-op if
    /// any of them is open again, or its Space is gone.
    public mutating func undoCloseFolder(_ closed: ClosedFolder) {
        let ids = Set(closed.tabs.map(\.tab.id))
        guard folder(closed.folder.id) == nil, !tabs.contains(where: { ids.contains($0.id) }),
              space(closed.folder.spaceID) != nil else { return }
        archived.removeAll { ids.contains($0.id) }
        folders.append(closed.folder)
        for (index, tab) in closed.tabs { tabs.insert(tab, at: min(index, tabs.endIndex)) }
        if let active = closed.activeTabID, ids.contains(active), activeSpaceID == closed.folder.spaceID {
            activeTabID = active
        }
    }

    /// Puts the tab back in `folder` after a move took it out (Move to Space's Undo): in it again if
    /// the folder is still there, or the folder back with it if the move emptied it. No-op once the
    /// tab is in another Space than the folder's or of another kind than its tabs.
    public mutating func rejoinFolder(_ tabID: UUID, _ folder: Folder) {
        guard let tab = tab(tabID), tab.spaceID == folder.spaceID, tab.folderID == nil else { return }
        if self.folder(folder.id) != nil {
            if isPinnedFolder(folder.id) == tab.isPinned { addToFolder(tabID, folder.id) }
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        folders.append(folder)
        tabs[index].folderID = folder.id
        if tabs[index].isPinned { tabs[index].pinPlace = .list }
    }

    /// Archives the tabs (pinned ones as if unpinned), each remembering `folder`, then drops the folder.
    mutating func archiveTogether(_ tabIDs: [UUID], folder: Folder, now: Date) {
        for tabID in tabIDs {
            if let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isPinned {
                tabs[index].kind = .today
                tabs[index].pinnedURL = nil
                tabs[index].pinnedTitle = nil
                tabs[index].pinPlace = .tile
            }
            archive(tabID: tabID, now: now)
        }
        let ids = Set(tabIDs)
        for index in archived.indices where ids.contains(archived[index].id) { archived[index].folder = ArchivedFolder(folder) }
        folders.removeAll { $0.id == folder.id }
    }

    // MARK: Archiving

    /// The Space's folders (never pinned ones) whose tabs are all idle for `policy` and none of them
    /// the active tab: `runArchive` archives each whole.
    func foldersDue(inSpace spaceID: UUID, policy: ArchivePolicy, now: Date) -> [Folder] {
        guard let interval = policy.interval else { return [] }
        return folders.filter { folder in
            guard folder.spaceID == spaceID else { return false }
            let members = tabs.filter { $0.folderID == folder.id }
            return !members.isEmpty && members.allSatisfy { tab in
                !tab.isPinned && tab.id != activeTabID && now.timeIntervalSince(tab.lastViewedAt) >= interval
            }
        }
    }

    /// Brings back every archived tab of `entry`'s folder, in a folder again (with the same ID), first
    /// among the other tabs of the Space it reopens in, `entry` the active tab.
    mutating func restoreFolder(of entry: ArchivedTab, now: Date) -> Tab? {
        guard let archivedFolder = entry.folder else { return nil }
        let entries = archived.filter { $0.folder?.id == archivedFolder.id }
        archived.removeAll { $0.folder?.id == archivedFolder.id }
        let spaceID = entry.spaceID != Space.incognitoID && space(entry.spaceID)?.isArchived == false
            ? entry.spaceID : spaceOutsideIncognito
        let folderID = folder(archivedFolder.id) == nil ? archivedFolder.id : UUID()
        folders.append(Folder(id: folderID, spaceID: spaceID, name: archivedFolder.name, icon: archivedFolder.icon,
                              createdAt: now))
        var restored: Tab?
        // Archived in the folder's order, which `listedTabs` shows reversed.
        for item in entries.reversed() {
            let tab = Tab(spaceID: spaceID, url: item.url, title: item.title, kind: .today, createdAt: now, folderID: folderID)
            tabs.append(tab)
            if item.id == entry.id { restored = tab }
        }
        guard let restored else { return nil }
        if spaceID != activeSpaceID, let activeTabID { markViewed(tabID: activeTabID, now: now) }
        activeSpaceID = spaceID
        activate(tabID: restored.id, now: now)
        return restored
    }

    // MARK: Keeping folders whole

    /// Drops folders that hold no tab.
    mutating func pruneFolders() {
        let used = Set(tabs.compactMap(\.folderID))
        folders.removeAll { !used.contains($0.id) }
    }

    /// For `normalize()`: folder IDs are unique and each folder is of an existing Space (not Incognito);
    /// a tab's folder exists and is of its Space; Incognito tabs are in none; a folder's tabs are all of
    /// the kind of its first one (others leave it), and a pinned folder's are list pins;
    /// a folder with no tab goes.
    mutating func normalizeFolders() {
        var seen = Set<UUID>()
        let spaceIDs = Set(spaces.map(\.id))
        folders.removeAll { !seen.insert($0.id).inserted || !spaceIDs.contains($0.spaceID) }
        let folderSpaces = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.spaceID) })
        var kinds: [UUID: TabKind] = [:]
        for index in tabs.indices {
            guard let folderID = tabs[index].folderID else { continue }
            let tab = tabs[index]
            if folderSpaces[folderID] != tab.spaceID || tab.isIncognito {
                tabs[index].folderID = nil
                continue
            }
            let kind = kinds[folderID] ?? tab.kind
            kinds[folderID] = kind
            if tab.kind != kind { tabs[index].folderID = nil }
        }
        for index in tabs.indices where tabs[index].folderID != nil && tabs[index].isPinned {
            tabs[index].pinPlace = .list
        }
        pruneFolders()
    }
}
