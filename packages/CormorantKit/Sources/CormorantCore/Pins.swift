import Foundation

// MARK: - Pinned tabs
//
// A pinned tab is a tab you keep: it never archives, and it remembers the page it was pinned on
// (`pinnedURL`). Closing it doesn't archive it: it goes back to that page, unloaded, and stays pinned.
// A Space's pins are in `tabs` order, so pinning, moving one to another Space and reordering put it
// where it goes in that array. Incognito tabs can't be pinned: a pin is saved.

extension Tab {
    public var isPinned: Bool { kind == .pinned }

    /// What a pinned tab is called: its new name, else its page's title, else the host.
    public var pinName: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let pinnedTitle, !pinnedTitle.isEmpty { return pinnedTitle }
        return pinnedURL?.host() ?? displayTitle
    }

    /// A pinned tab that has left its pinned page (another page, or another part of it: only the
    /// fragment, case of the scheme and host, and a trailing slash don't count). False for other tabs.
    public var isAwayFromPin: Bool {
        guard isPinned, let pinnedURL else { return false }
        return Self.pageKey(pinnedURL) != Self.pageKey(url)
    }

    /// The title search matches the tab by: its own name (a pin's, or Rename's) as well as its page's.
    public var searchTitle: String {
        let name = isPinned ? pinName : (customTitle ?? "")
        let page = title.isEmpty ? (url?.host() ?? displayTitle) : title
        return name.isEmpty || name == page ? page : "\(name) \(page)"
    }

    /// `url` as `isAwayFromPin` compares it.
    static func pageKey(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        return components.string
    }
}

/// What `unpin` changed, for its Undo (`undoUnpin`).
public struct UnpinnedTab: Sendable, Equatable {
    public let tabID: UUID
    let pinnedURL: URL?
    let pinnedTitle: String?
    let customTitle: String?
    let pinPlace: PinPlace
    /// Its folder, kept whole in case unpinning it emptied the folder.
    let folder: Folder?
    let lastViewedAt: Date
    /// The pin it was before in its Space; nil when it was last.
    let before: UUID?
}

extension BrowserState {
    /// The Space's pinned tabs, in pin order.
    public func pinnedTabs(inSpace spaceID: UUID) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned }
    }

    /// The Space's other tabs, most recently viewed first.
    public func unpinnedTabs(inSpace spaceID: UUID) -> [Tab] {
        tabs(inSpace: spaceID).filter { !$0.isPinned }
    }

    /// The Space's other tabs in the order a list of them keeps (the Mac's sidebar): the newest first,
    /// a tab opened from a page under it (`openTab(under:)`). That's `tabs` last first, so tabs saved
    /// before there was a list are listed newest first.
    public func listedTabs(inSpace spaceID: UUID) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && !$0.isPinned }.reversed()
    }

    /// Whether `pin(tabID:)` would pin the tab: a web page (http or https), not Incognito, not pinned yet.
    public func canPin(_ tabID: UUID) -> Bool {
        guard let tab = tab(tabID), !tab.isPinned, !tab.isIncognito,
              let scheme = tab.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The pin after this one in its Space, nil when it's last or not a pin: where `movePin(_:before:)`
    /// puts it back.
    public func pinAfter(_ tabID: UUID) -> UUID? {
        guard let tab = tab(tabID), tab.isPinned else { return nil }
        let pins = pinnedTabs(inSpace: tab.spaceID)
        guard let index = pins.firstIndex(where: { $0.id == tabID }), index + 1 < pins.count else { return nil }
        return pins[index + 1].id
    }

    /// Pins the tab on the page it's on, last among its Space's pins in `place`, if `canPin` says it
    /// can. It leaves any folder it was in, and keeps any name Rename gave it. Returns whether it pinned.
    @discardableResult
    public mutating func pin(tabID: UUID, place: PinPlace = .tile) -> Bool {
        guard canPin(tabID), let index = tabs.firstIndex(where: { $0.id == tabID }),
              let url = tabs[index].url else { return false }
        var tab = tabs.remove(at: index)
        tab.kind = .pinned
        tab.pinnedURL = url
        tab.pinnedTitle = tab.title.isEmpty ? nil : tab.title
        tab.pinPlace = place
        tab.folderID = nil
        tabs.append(tab)
        pruneFolders()
        return true
    }

    /// Moves a pin between the tiles and the pinned list, last there. A list pin leaves its folder.
    public mutating func movePin(_ tabID: UUID, to place: PinPlace) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isPinned,
              tabs[index].pinPlace != place || tabs[index].folderID != nil else { return }
        var tab = tabs.remove(at: index)
        tab.pinPlace = place
        tab.folderID = nil
        tabs.append(tab)
        pruneFolders()
    }

    /// Unpins the tab: one of the Space's other tabs again, listed first, on the page it's on, counted as viewed now
    /// (so it doesn't archive at once for the time it sat pinned), out of any folder, keeping any name
    /// Rename gave it. Returns what `undoUnpin` needs, or nil for an unknown or unpinned tab.
    @discardableResult
    public mutating func unpin(tabID: UUID, now: Date = .now) -> UnpinnedTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isPinned else { return nil }
        let tab = tabs[index]
        let undo = UnpinnedTab(tabID: tabID, pinnedURL: tab.pinnedURL, pinnedTitle: tab.pinnedTitle,
                               customTitle: tab.customTitle, pinPlace: tab.pinPlace, folder: tab.folderID.flatMap(folder),
                               lastViewedAt: tab.lastViewedAt, before: pinAfter(tabID))
        tabs[index].kind = .today
        tabs[index].pinnedURL = nil
        tabs[index].pinnedTitle = nil
        tabs[index].pinPlace = .tile
        tabs[index].folderID = nil
        tabs[index].lastViewedAt = max(tab.lastViewedAt, now)
        // Listed first (`listedTabs`), not wherever it sat among the pins.
        tabs.append(tabs.remove(at: index))
        pruneFolders()
        return undo
    }

    /// Pins the tab `unpin` unpinned again, as it was: its page, name and place among the pins. No-op
    /// once it has closed or been pinned again.
    public mutating func undoUnpin(_ undo: UnpinnedTab) {
        guard let index = tabs.firstIndex(where: { $0.id == undo.tabID }), !tabs[index].isPinned,
              !tabs[index].isIncognito else { return }
        tabs[index].kind = .pinned
        tabs[index].pinnedURL = undo.pinnedURL ?? tabs[index].url
        tabs[index].pinnedTitle = undo.pinnedTitle
        tabs[index].customTitle = undo.customTitle
        tabs[index].pinPlace = undo.pinPlace
        tabs[index].lastViewedAt = undo.lastViewedAt
        tabs[index].folderID = nil
        if let folder = undo.folder, folder.spaceID == tabs[index].spaceID {
            if self.folder(folder.id) == nil { folders.append(folder) }
            if isPinnedFolder(folder.id) || !tabs.contains(where: { $0.folderID == folder.id }) {
                tabs[index].folderID = folder.id
            }
        }
        movePin(undo.tabID, before: undo.before)
        normalizeFolders()
    }

    /// Gives the tab a name of its own; an empty name (or only spaces) goes back to its page's title.
    public mutating func rename(_ tabID: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = name.isEmpty ? nil : name
    }

    /// `rename`, for a pinned tab only.
    public mutating func renamePin(_ tabID: UUID, to name: String) {
        guard tab(tabID)?.isPinned == true else { return }
        rename(tabID, to: name)
    }

    /// Moves a pin to just before `before`, a pin in the same Space, or last with nil (or a tab that
    /// isn't one of its Space's pins).
    public mutating func movePin(_ tabID: UUID, before: UUID?) {
        guard before != tabID, let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isPinned else { return }
        let tab = tabs.remove(at: index)
        if let before, let target = tabs.firstIndex(where: { $0.id == before && $0.isPinned && $0.spaceID == tab.spaceID }) {
            tabs.insert(tab, at: target)
        } else {
            tabs.append(tab)
        }
    }

    /// A pin dragged onto another of its Space's pins takes its place: just before it when coming from
    /// its right, just after it when coming from its left, as the iPhone's row shows them (the tiles,
    /// then the pinned list). Dropped on a pin of the other place (not one in a folder), it joins that
    /// place, out of any folder. Returns whether it moved.
    @discardableResult
    public mutating func movePin(_ tabID: UUID, onto target: UUID) -> Bool {
        guard tabID != target, let tab = tab(tabID), tab.isPinned,
              let targetTab = self.tab(target), targetTab.isPinned, targetTab.spaceID == tab.spaceID else { return false }
        if targetTab.pinPlace != tab.pinPlace || tab.folderID != targetTab.folderID {
            guard targetTab.folderID == nil, let from = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
            var moving = tabs.remove(at: from)
            moving.pinPlace = targetTab.pinPlace
            moving.folderID = nil
            guard let to = tabs.firstIndex(where: { $0.id == target }) else { return false }
            // A tile joining the list comes from the target's left; a list pin joining the tiles, from its right.
            tabs.insert(moving, at: tab.pinPlace == .tile && targetTab.pinPlace == .list ? to + 1 : to)
            pruneFolders()
            return true
        }
        let pins = pinnedTabs(inSpace: tab.spaceID).filter { $0.pinPlace == tab.pinPlace }
        guard let from = pins.firstIndex(where: { $0.id == tabID }),
              let to = pins.firstIndex(where: { $0.id == target }) else { return false }
        movePin(tabID, before: from < to ? (to + 1 < pins.count ? pins[to + 1].id : nil) : target)
        return true
    }

    /// A pinned tab back on its pinned page, as a fresh tab: a new ID, so nothing of its web view, its
    /// back/forward list or its snapshot is kept, in the same place among the pins. Still the active
    /// tab if it was. Returns the new tab, or nil for an unknown or unpinned tab.
    @discardableResult
    public mutating func resetPin(_ tabID: UUID) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isPinned else { return nil }
        let old = tabs[index]
        let fresh = Tab(spaceID: old.spaceID, url: old.pinnedURL ?? old.url, title: old.pinnedTitle ?? "",
                        kind: .pinned, createdAt: old.createdAt, lastViewedAt: old.lastViewedAt,
                        pinnedURL: old.pinnedURL ?? old.url, pinnedTitle: old.pinnedTitle, customTitle: old.customTitle,
                        pinPlace: old.pinPlace, folderID: old.folderID)
        tabs[index] = fresh
        if activeTabID == tabID { activeTabID = fresh.id }
        return fresh
    }

    /// Closes the tab. Any but a pinned one is archived (`archive(tabID:)`). A pinned tab stays pinned:
    /// it goes back to its pinned page, unloaded (`resetPin`), and if it was the active tab the Space's
    /// most recently viewed other tab is active instead (none when it has no other).
    public mutating func close(tabID: UUID, now: Date = .now) {
        guard let tab = tab(tabID), tab.isPinned else {
            archive(tabID: tabID, now: now)
            return
        }
        if activeTabID == tabID { activeTabID = tabAfterArchiving(tabID) }
        resetPin(tabID)
    }

    /// For `normalize()`: an Incognito tab or one with no page is never pinned, and a pinned tab always
    /// has a pinned page (a file from a build that didn't keep one: the page it's on). Other tabs have
    /// no pinned page or title and count as tiles (`pinPlace`), which pinning sets.
    mutating func normalizePins() {
        for index in tabs.indices {
            if tabs[index].isPinned, tabs[index].isIncognito || tabs[index].url == nil {
                tabs[index].kind = .today
            }
            if tabs[index].isPinned {
                if tabs[index].pinnedURL == nil { tabs[index].pinnedURL = tabs[index].url }
            } else {
                tabs[index].pinnedURL = nil
                tabs[index].pinnedTitle = nil
                tabs[index].pinPlace = .tile
            }
        }
    }
}
