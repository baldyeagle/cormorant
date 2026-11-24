import CormorantCore
import Foundation

/// A tab the Move to Space sheet is up for.
public struct MoveRequest: Identifiable {
    public let tabID: UUID
    public var id: UUID { tabID }

    public init(tabID: UUID) {
        self.tabID = tabID
    }
}

/// A Space a tab can move to, as the move menus and sheet list it.
public struct MoveDestination: Identifiable {
    public let space: Space
    /// The Space the tab is in: listed, checked, not choosable.
    public let isCurrent: Bool
    /// Its profile isn't the one the tab's Space uses: the page loads again there, signed in with that
    /// profile's accounts.
    public let changesProfile: Bool
    public let profile: Profile
    public let tabCount: Int
    public var id: UUID { space.id }

    /// "Here now" for the tab's own Space. Otherwise its tab count, then its profile where it isn't the
    /// default or the move changes profile, then "Reloads" if it does: "1 tab · Vialumi profile · Reloads".
    public var subtitle: String {
        if isCurrent { return "Here now" }
        var parts = [tabCount == 1 ? "1 tab" : "\(tabCount) tabs"]
        if changesProfile || !profile.isDefault { parts.append("\(profile.name) profile") }
        if changesProfile { parts.append("Reloads") }
        return parts.joined(separator: " · ")
    }
}

/// Another Space a link can open in, for the link menu's Open in Space.
public struct LinkSpaceOption {
    public let space: Space
    /// Its profile, where it isn't the default.
    public let profileName: String?
    /// It uses the opener's profile, so a tab there can adopt the menu preview's page (loaded with the
    /// opener's website data). Elsewhere the tab loads the link itself.
    public let adoptsPreview: Bool
}

/// Moving tabs between Spaces, opening links in another, and the toasts that say so. None of it
/// appears with only one Space.
extension BrowserStore {
    /// More than one of your own Spaces, so a tab or link has somewhere to go. Incognito doesn't count:
    /// nothing moves in or out of it.
    var hasSpacesToMoveBetween: Bool { state.switchableSpaces.count > 1 }

    // MARK: Moving a tab

    /// Every Space a tab could be in, in order, its own marked current. Empty with only one Space, or
    /// for an unknown or Incognito tab.
    public func moveDestinations(for tabID: UUID) -> [MoveDestination] {
        guard hasSpacesToMoveBetween, let tab = state.tab(tabID), !tab.isIncognito else { return [] }
        return state.switchableSpaces.map { space in
            MoveDestination(space: space, isCurrent: space.id == tab.spaceID,
                            changesProfile: state.moveChangesProfile(tabID, toSpace: space.id),
                            profile: state.profile(forSpace: space.id),
                            tabCount: state.tabCount(inSpace: space.id))
        }
    }

    /// Moves the tab at once and goes with it: its new Space shows it. A toast says "Moved" (where to is
    /// on its badge and the bar; VoiceOver hears it), led by Back to the Space you left (← and its badge;
    /// the tab stays) and ending in Undo (back where you were, the tab with you).
    public func moveTab(_ tabID: UUID, toSpace spaceID: UUID) {
        guard hasSpacesToMoveBetween, let tab = state.tab(tabID), !tab.isIncognito,
              let destination = state.space(spaceID), !destination.isIncognito else { return }
        let from = tab.spaceID, wasActive = state.activeTabID == tabID, viewedAt = tab.lastViewedAt
        let pinnedBefore = state.pinAfter(tabID)
        let left = state.activeSpace
        guard applyMove(of: tabID, { $0.moveTabAndFollow(tabID, toSpace: spaceID) }) != nil else { return }
        let back = left.id == spaceID ? nil : Toast.Action("Back to \(left.name)", space: left) { [weak self] in
            self?.switchToSpace(left.id)
        }
        showToast(Toast(icon: .space(destination), message: "Moved", spokenText: "Moved to \(destination.name)",
                        leadingAction: back, actions: [
            Toast.Action("Undo") { [weak self] in
                self?.applyMove(of: tabID) {
                    $0.moveTabBack(tabID, toSpace: from, wasActive: wasActive, lastViewedAt: viewedAt,
                                   returningTo: left.id, pinnedBefore: pinnedBefore)
                }
            },
        ]))
    }

    /// Asks the browser for the Move to Space sheet for the tab (a toast's Move…).
    func requestMove(of tabID: UUID) {
        guard hasSpacesToMoveBetween, state.tab(tabID)?.isIncognito == false else { return }
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

    /// The Spaces other than the opener's, in order; empty with only one Space, and from Incognito,
    /// whose links leave it only by Copy or Share.
    func spacesToOpenLinks(from openerID: UUID) -> [LinkSpaceOption] {
        guard hasSpacesToMoveBetween, let opener = state.tab(openerID), !opener.isIncognito else { return [] }
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
    public func openLink(_ url: URL, inSpace spaceID: UUID, from opener: TabSession?, handoff: LinkPreviewHandoff?) -> Bool {
        guard hasSpacesToMoveBetween, let space = state.space(spaceID), !space.isArchived, !space.isIncognito,
              spaceID != opener.flatMap({ state.tab($0.tabID)?.spaceID }) else { return false }
        guard let tabID = openLink(url, inBackground: true, inSpace: spaceID, from: opener, handoff: handoff)
        else { return false }
        showToast(Toast(icon: .space(space), message: "Opened in \(space.name)", actions: [
            Toast.Action("Show") { [weak self] in self?.show(tabID, in: spaceID) },
        ]))
        return true
    }

    // MARK: Links from other apps

    /// Links from other apps open straight to the page, in the Space picked for them in the share
    /// extension, else a Focus filter's, else the one last used (`openInboxAndPending`). With more than
    /// one Space, a toast says which, notes a Focus filter that chose it, and for a single link offers
    /// Move… to another. It never says which app a link came from: the app can't know.
    func didOpenFromOtherApp(_ links: [OpenedLink]) {
        guard hasSpacesToMoveBetween, let last = links.last, let space = state.space(last.spaceID) else { return }
        var names: [String] = []
        for link in links {
            if let name = state.space(link.spaceID)?.name, !names.contains(name) { names.append(name) }
        }
        let message = links.count == 1
            ? "Opened in \(space.name)"
            : "Opened \(links.count) tabs in \(names.formatted(.list(type: .and)))"
        let actions = links.count == 1 ? [Toast.Action("Move…") { [weak self] in self?.requestMove(of: last.tabID) }] : []
        let note = links.contains { $0.reason == .focus } ? Toast.Note(text: "Focus", symbol: "moon.fill") : nil
        showToast(Toast(icon: .space(space), message: message, note: note, actions: actions,
                        tabID: links.count == 1 ? last.tabID : nil))
    }
}

/// A tab opened for a link from another app, where it opened, and why there.
public struct OpenedLink {
    public let tabID: UUID
    public let spaceID: UUID
    let reason: LinkDestinationReason
}
