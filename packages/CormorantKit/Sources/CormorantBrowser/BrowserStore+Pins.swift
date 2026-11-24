import CormorantCore
import Foundation

/// Pinned tabs: pinning and unpinning (with a toast and Undo), renaming, reordering, and taking one
/// back to its pinned page. What a pin is lives in CormorantCore's `Pins.swift`; closing one is
/// `close(_:)`, which leaves it pinned.
extension BrowserStore {
    /// The active Space's pinned tabs, in pin order: the switcher's tiles and a new tab's.
    public var pinnedTabs: [Tab] { state.pinnedTabs(inSpace: state.activeSpaceID) }

    /// The active Space's other tabs, most recently viewed first: the switcher's cards.
    public var unpinnedTabs: [Tab] { state.unpinnedTabs(inSpace: state.activeSpaceID) }

    /// The active Space's other tabs in the order a list of them keeps (`BrowserState.listedTabs`).
    public var listedTabs: [Tab] { state.listedTabs(inSpace: state.activeSpaceID) }

    /// Whether the tab can be pinned: a web page, not Incognito, not pinned already.
    public func canPin(_ tabID: UUID) -> Bool { state.canPin(tabID) }

    /// Pins the tab on the page it's on. A toast says so, with Undo.
    public func pin(_ tabID: UUID) {
        var pinned = false
        changeState { pinned = $0.pin(tabID: tabID) }
        guard pinned, let tab = state.tab(tabID) else { return }
        let space = state.space(tab.spaceID)
        let message = hasSpacesToSwitch ? "Pinned to \(space?.name ?? "Home")" : "Pinned"
        showToast(Toast(icon: .symbol("pin.fill"), message: message, actions: [
            Toast.Action("Undo") { [weak self] in
                self?.changeState { _ = $0.unpin(tabID: tabID) }
            },
        ], tabID: tabID))
    }

    /// Unpins the tab, which joins the Space's cards on the page it's on. A toast says so, with Undo.
    public func unpin(_ tabID: UUID) {
        var undo: UnpinnedTab?
        changeState { undo = $0.unpin(tabID: tabID) }
        guard let undo else { return }
        showToast(Toast(icon: .symbol("pin.slash"), message: "Unpinned", actions: [
            Toast.Action("Undo") { [weak self] in
                self?.changeState { $0.undoUnpin(undo) }
            },
        ], tabID: tabID))
    }

    public func renamePin(_ tabID: UUID, to name: String) {
        changeState { $0.renamePin(tabID, to: name) }
    }

    /// Moves the pin to just before `before`, or last with nil.
    public func movePin(_ tabID: UUID, before: UUID?) {
        changeState { $0.movePin(tabID, before: before) }
    }

    /// The pin takes the place of the one it's dragged onto (`BrowserState.movePin(_:onto:)`).
    @discardableResult
    public func movePin(_ tabID: UUID, onto target: UUID) -> Bool {
        var moved = false
        changeState { moved = $0.movePin(tabID, onto: target) }
        return moved
    }

    /// Takes a pinned tab back to its pinned page. With a web view, it loads there as any page would
    /// (Back returns to where it was); without one, it starts again there, its back/forward list gone.
    public func backToPinnedPage(_ tabID: UUID) {
        guard let tab = state.tab(tabID), tab.isPinned, let pinnedURL = tab.pinnedURL else { return }
        if let session = existingSession(for: tabID) {
            session.load(pinnedURL)
        } else {
            changeState { $0.resetPin(tabID) }
        }
    }
}
