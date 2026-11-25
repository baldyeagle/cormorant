import CormorantCore
import Foundation

/// Folders, the tiles and the pinned list (CormorantCore's `Folders.swift`), for the active Space.
extension BrowserStore {
    /// The active Space's tile pins.
    public var tilePins: [Tab] { state.tilePins(inSpace: state.activeSpaceID) }

    /// The active Space's pinned list: list pins and pinned folders.
    public var pinnedList: [SidebarItem] { state.pinnedList(inSpace: state.activeSpaceID) }

    /// The active Space's other tabs and folders, as a list keeps them (`listedTabs`).
    public var listedItems: [SidebarItem] { state.listedItems(inSpace: state.activeSpaceID) }

    /// The active Space's other tabs and folders, most recently viewed first: the iPhone's cards.
    public var unpinnedItems: [SidebarItem] { state.unpinnedItems(inSpace: state.activeSpaceID) }

    /// The tiles, then the pinned list: the iPhone's row of tiles.
    public var pinRow: [SidebarItem] { state.pinRow(inSpace: state.activeSpaceID) }

    /// The folders of the tab's Space it could join (`addToFolder`).
    public func folders(for tabID: UUID) -> [Folder] {
        guard let tab = state.tab(tabID) else { return [] }
        return state.folders(inSpace: tab.spaceID).filter { state.canAdd(tabID, toFolder: $0.id) }
    }

    /// Puts the tab in a new folder where it was. Returns the folder's ID.
    @discardableResult
    public func newFolder(with tabID: UUID, name: String = Folder.defaultName) -> UUID? {
        var folder: Folder?
        changeState { folder = $0.newFolder(with: tabID, name: name) }
        return folder?.id
    }

    public func addToFolder(_ tabID: UUID, _ folderID: UUID) {
        changeState { $0.addToFolder(tabID, folderID) }
    }

    public func removeFromFolder(_ tabID: UUID) {
        changeState { $0.removeFromFolder(tabID) }
    }

    /// Removes the folder, its tabs staying where they are.
    public func ungroupFolder(_ folderID: UUID) {
        changeState { $0.ungroupFolder(folderID) }
    }

    public func renameFolder(_ folderID: UUID, to name: String) {
        changeState { $0.renameFolder(folderID, to: name) }
    }

    public func setFolderIcon(_ folderID: UUID, _ icon: String?) {
        changeState { $0.setFolderIcon(folderID, icon) }
    }

    public func setFolderOpen(_ folderID: UUID, _ isOpen: Bool) {
        changeState { $0.setFolderOpen(folderID, isOpen) }
    }

    /// Pins the folder into the pinned list, or unpins it among the other tabs.
    public func moveFolder(_ folderID: UUID, toPinned pinned: Bool) {
        changeState { $0.moveFolder(folderID, toPinned: pinned) }
    }

    /// Closes the folder and its tabs, which go to the archive together: restoring one later brings
    /// them all back in the folder. A toast says so, with Undo, which puts it all back as it was.
    public func closeFolder(_ folderID: UUID) {
        var closed: ClosedFolder?
        changeState { closed = $0.closeFolder(folderID) }
        guard let closed, let name = state.archived.last(where: { $0.folder?.id == folderID })?.folder?.name else { return }
        showToast(Toast(icon: .symbol("folder"), message: "Closed \(name)", actions: [
            Toast.Action("Undo") { [weak self] in
                self?.changeState { $0.undoCloseFolder(closed) }
            },
        ]))
    }
}
