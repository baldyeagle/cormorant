import CormorantCore
import Foundation

/// Manage Spaces: presenting it, and the changes it makes.
extension BrowserStore {
    // MARK: Presentation

    /// Opens Manage Spaces from the browser's root, closing whatever else is up first (the caret sheet
    /// and Settings on it, the switcher, the search panel). Settings' Spaces row calls it; so will the
    /// Space strip and the tabs button's menu.
    func showManageSpaces(editing spaceID: UUID? = nil) {
        guard isLoaded else { return }
        spaceToEdit = spaceID
        showsManageSpaces = true
        manageSpacesRequest += 1
    }

    func dismissManageSpaces() {
        showsManageSpaces = false
        spaceToEdit = nil
    }

    // MARK: Changes

    /// Adds a Space at the end of the list and switches to it, then closes Manage Spaces: the Space is
    /// empty, so the browser brings up the search panel. A blank name (after trimming) adds nothing.
    func createSpace(name: String, icon: SpaceIcon, color: Swatch) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !name.isEmpty else { return }
        changeState { state in
            let space = state.addSpace(name: name, icon: icon, color: color)
            state.switchToSpace(space.id)
        }
        dismissManageSpaces()
        // From Settings' page: into the new Space, past Settings and the caret sheet.
        if isManagingSpacesInSettings { closeSheetsRequest += 1 }
    }

    /// Saves Edit Space's fields. A blank name (after trimming) keeps the old one.
    func updateSpace(_ spaceID: UUID, name: String, icon: SpaceIcon, color: Swatch, archivePolicy: ArchivePolicy) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        changeState { state in
            state.updateSpace(spaceID) { space in
                if !name.isEmpty { space.name = name }
                space.icon = icon
                space.color = color
                space.archivePolicy = archivePolicy
            }
        }
    }

    /// Takes the Space out of switching with its tabs, whose pages stop until it's restored; from the
    /// active Space, back to Home.
    func archiveSpace(_ spaceID: UUID) {
        changeState { $0.archiveSpace(spaceID) }
        if state.space(spaceID)?.isArchived == true { releaseWebViews(inSpace: spaceID) }
    }

    func restoreSpace(_ spaceID: UUID) {
        changeState { $0.restoreSpace(spaceID) }
    }

    /// Deletes the Space, its tabs going to the tab archive; from the active Space, back to Home.
    func deleteSpace(_ spaceID: UUID) {
        changeState { $0.deleteSpace(spaceID) }
    }

    func moveSpace(_ spaceID: UUID, before otherID: UUID?) {
        changeState { $0.moveSpace(spaceID, before: otherID) }
    }
}
