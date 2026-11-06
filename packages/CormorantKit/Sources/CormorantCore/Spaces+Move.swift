import Foundation

// MARK: - Moving tabs between Spaces (Move to Space, its Undo)

extension BrowserState {
    /// The open tab with this ID, if any.
    public func tab(_ tabID: UUID) -> Tab? { tabs.first { $0.id == tabID } }

    /// Whether `moveTab(_:toSpace:)` would load the tab in another profile: the destination's profile
    /// differs from the profile of the Space the tab is in. False for an unknown tab or Space. The move
    /// menus say "Reloads" on such a destination.
    public func moveChangesProfile(_ tabID: UUID, toSpace spaceID: UUID) -> Bool {
        guard let tab = tab(tabID), space(spaceID) != nil else { return false }
        return profile(forSpace: tab.spaceID).id != profile(forSpace: spaceID).id
    }

    /// Undoes a `moveTab`: moves the tab back to `spaceID`, as if it had never gone. When it was the
    /// active tab as it left (`wasActive`) and that Space is still the active one, it's the active tab
    /// again. Otherwise it takes back `lastViewedAt`, its last view before the move, so it returns to its
    /// place among the Space's tabs (and its idle time for archiving); nil counts the move back as a view.
    /// Otherwise as `moveTab`, including its return value: nil when nothing moved (the tab closed, the
    /// Space archived or deleted meanwhile, or the tab already back).
    @discardableResult
    public mutating func moveTabBack(_ tabID: UUID, toSpace spaceID: UUID, wasActive: Bool,
                                     lastViewedAt: Date? = nil, now: Date = .now) -> Bool? {
        guard let changesProfile = moveTab(tabID, toSpace: spaceID, now: now) else { return nil }
        if !wasActive || spaceID != activeSpaceID, let lastViewedAt, activeTabID != tabID,
           let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].lastViewedAt = min(lastViewedAt, now)
        }
        if wasActive, spaceID == activeSpaceID, activeTabID != tabID {
            if let activeTabID { markViewed(tabID: activeTabID, now: now) }
            activate(tabID: tabID, now: now)
        }
        return changesProfile
    }
}
