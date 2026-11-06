import CormorantCore
import Foundation

/// A tab the Move to Space sheet is up for.
struct MoveRequest: Identifiable {
    let tabID: UUID
    var id: UUID { tabID }
}

/// A Space a tab can move to, as the move menus and sheet list it.
struct MoveDestination: Identifiable {
    let space: Space
    /// The Space the tab is in: listed, checked, not choosable.
    let isCurrent: Bool
    /// Its profile isn't the one the tab's Space uses: the page reloads there.
    let changesProfile: Bool
    let profile: Profile
    let tabCount: Int
    var id: UUID { space.id }

    /// "Here now" for the tab's own Space. Otherwise its tab count, then its profile where it isn't the
    /// default or the move changes profile, then "Reloads" if it does: "1 tab · Vialumi profile · Reloads".
    var subtitle: String {
        if isCurrent { return "Here now" }
        var parts = [tabCount == 1 ? "1 tab" : "\(tabCount) tabs"]
        if changesProfile || !profile.isDefault { parts.append("\(profile.name) profile") }
        if changesProfile { parts.append("Reloads") }
        return parts.joined(separator: " · ")
    }
}

/// Another Space a link can open in, for the link menu's Open in Space.
struct LinkSpaceOption {
    let space: Space
    /// Its profile, where it isn't the default.
    let profileName: String?
    /// It uses the opener's profile, so a tab there can adopt the menu preview's page (loaded with the
    /// opener's website data). Elsewhere the tab loads the link itself.
    let adoptsPreview: Bool
}

/// Moving tabs between Spaces, opening links in another, and the toasts that say so. None of it
/// appears with only one Space.
extension BrowserStore {
    // MARK: Moving a tab

    /// Every Space a tab could be in, in order, its own marked current. Empty with only one Space, or
    /// for an unknown tab.
    func moveDestinations(for tabID: UUID) -> [MoveDestination] {
        guard hasSpacesToSwitch, let tab = state.tab(tabID) else { return [] }
        return state.switchableSpaces.map { space in
            MoveDestination(space: space, isCurrent: space.id == tab.spaceID,
                            changesProfile: state.moveChangesProfile(tabID, toSpace: space.id),
                            profile: state.profile(forSpace: space.id),
                            tabCount: state.tabCount(inSpace: space.id))
        }
    }

    /// Moves the tab at once. The Space it left shows its next tab if it was on screen (or the search
    /// panel, empty). A toast says where it went, with Undo and Show.
    func moveTab(_ tabID: UUID, toSpace spaceID: UUID) {
        guard hasSpacesToSwitch, let tab = state.tab(tabID), let destination = state.space(spaceID) else { return }
        let from = tab.spaceID, wasActive = state.activeTabID == tabID, viewedAt = tab.lastViewedAt
        guard applyMove(of: tabID, { $0.moveTab(tabID, toSpace: spaceID) }) != nil else { return }
        showToast(Toast(icon: .space(destination), message: "Moved to \(destination.name)", actions: [
            Toast.Action("Undo") { [weak self] in
                self?.applyMove(of: tabID) {
                    $0.moveTabBack(tabID, toSpace: from, wasActive: wasActive, lastViewedAt: viewedAt)
                }
            },
            Toast.Action("Show") { [weak self] in self?.show(tabID, in: spaceID) },
        ]))
    }

    /// Asks the browser for the Move to Space sheet for the tab (a toast's Move…).
    func requestMove(of tabID: UUID) {
        guard hasSpacesToSwitch, state.tab(tabID) != nil else { return }
        moveRequest = MoveRequest(tabID: tabID)
    }

    /// Switches to the tab, in whatever Space it's in now; to `spaceID` if it has closed. Never into an
    /// archived Space (activating its tab would restore it).
    func show(_ tabID: UUID, in spaceID: UUID) {
        if let tab = state.tab(tabID) {
            if state.space(tab.spaceID)?.isArchived == false { activate(tabID) }
        } else if state.space(spaceID)?.isArchived == false {
            switchToSpace(spaceID)
        }
    }

    // MARK: Opening a link in another Space

    /// The Spaces other than the opener's, in order; empty with only one Space.
    func spacesToOpenLinks(from openerID: UUID) -> [LinkSpaceOption] {
        guard hasSpacesToSwitch, let opener = state.tab(openerID) else { return [] }
        let openerProfile = state.profile(forSpace: opener.spaceID).id
        return state.switchableSpaces.filter { $0.id != opener.spaceID }.map { space in
            let profile = state.profile(forSpace: space.id)
            return LinkSpaceOption(space: space, profileName: profile.isDefault ? nil : profile.name,
                                   adoptsPreview: profile.id == openerProfile)
        }
    }

    /// Opens the link in a background tab in `spaceID`, never switching there. A toast offers Show.
    /// Returns false if no tab was opened (one Space, or the Space is the opener's or archived).
    @discardableResult
    func openLink(_ url: URL, inSpace spaceID: UUID, from opener: TabSession?, handoff: LinkPreviewHandoff?) -> Bool {
        guard hasSpacesToSwitch, let space = state.space(spaceID), !space.isArchived,
              spaceID != opener.flatMap({ state.tab($0.tabID)?.spaceID }) else { return false }
        guard let tabID = openLink(url, inBackground: true, inSpace: spaceID, from: opener, handoff: handoff)
        else { return false }
        showToast(Toast(icon: .space(space), message: "Opened in \(space.name)", actions: [
            Toast.Action("Show") { [weak self] in self?.show(tabID, in: spaceID) },
        ]))
        return true
    }

    // MARK: Links from other apps

    /// Links from other apps open in the active Space, straight to the page. With more than one Space,
    /// a toast says which, and for a single link offers Move… to another.
    func didOpenFromOtherApp(_ tabIDs: [UUID]) {
        guard hasSpacesToSwitch, let last = tabIDs.last else { return }
        let space = state.activeSpace
        let message = tabIDs.count == 1 ? "Opened in \(space.name)" : "Opened \(tabIDs.count) tabs in \(space.name)"
        let actions = tabIDs.count == 1 ? [Toast.Action("Move…") { [weak self] in self?.requestMove(of: last) }] : []
        showToast(Toast(icon: .space(space), message: message, actions: actions))
    }
}
