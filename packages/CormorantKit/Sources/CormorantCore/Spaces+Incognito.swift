import Foundation

// MARK: - Incognito

/// Incognito is a Space of its own, built in like Home, on a profile of its own whose website data the
/// app keeps in memory only. It isn't in `BrowserState.spaces`: it exists while it has tabs (`space(_:)`
/// finds it then), shows last among the Spaces (`shownSpaces`), and none of it is ever saved: encoding
/// a state writes `persisted`, which leaves out Incognito and its tabs.
extension Space {
    public static let incognitoID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    /// Never archives its tabs on its own; closing one deletes it (`BrowserState.archive(tabID:)`).
    public static var incognito: Space {
        Space(id: incognitoID, name: "Incognito", color: .gray, profileID: Profile.incognitoID,
              archivePolicy: .off, createdAt: .distantPast)
    }

    public var isIncognito: Bool { id == Self.incognitoID }
}

extension Profile {
    /// Incognito's website data: in memory only, shared by its tabs, gone once the last one closes.
    /// Never in `BrowserState.profiles`, so no history or other saved data is ever kept for it.
    public static let incognitoID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    public static var incognito: Profile { Profile(id: incognitoID, name: "Incognito", color: .gray, createdAt: .distantPast) }

    public var isIncognito: Bool { id == Self.incognitoID }
}

extension Tab {
    /// The tab is in Incognito: never saved, and deleted rather than archived when it closes.
    public var isIncognito: Bool { spaceID == Space.incognitoID }
}

extension BrowserState {
    /// Any tab is open in Incognito, so the Space exists.
    public var isIncognitoOpen: Bool { tabs.contains(where: \.isIncognito) }

    /// The Spaces to show and switch between: the switchable ones, then Incognito while it's open.
    public var shownSpaces: [Space] { switchableSpaces + (isIncognitoOpen ? [.incognito] : []) }

    /// The active Space, or while that's Incognito, the one it goes back to: the Space that was active
    /// before it, if it can still be switched to, else Home. What a saved state, links from other apps
    /// and the share extension take as the Space last used.
    public var spaceOutsideIncognito: UUID {
        guard activeSpaceID == Space.incognitoID else { return activeSpaceID }
        if let spaceBeforeIncognito, space(spaceBeforeIncognito)?.isArchived == false { return spaceBeforeIncognito }
        return Space.defaultID
    }

    /// Opens a tab in Incognito, opening the Space if it isn't. Made active unless `activate` is false
    /// (a background tab), switching to Incognito if it isn't the active Space.
    @discardableResult
    public mutating func openIncognitoTab(url: URL?, title: String = "", under openerID: UUID? = nil,
                                          activate: Bool = true, now: Date = .now) -> Tab {
        let tab = Tab(spaceID: Space.incognitoID, url: url, title: title, kind: .today, createdAt: now)
        insert(tab, under: openerID)
        if activate {
            if activeSpaceID != Space.incognitoID, let activeTabID { markViewed(tabID: activeTabID, now: now) }
            activeSpaceID = Space.incognitoID
            activeTabID = tab.id
        }
        return tab
    }

    /// The state as it's saved: without Incognito's tabs, and while Incognito is active, on the Space it
    /// goes back to (`spaceOutsideIncognito`) and that Space's most recently viewed tab. Encoding a
    /// state always writes this.
    public var persisted: BrowserState {
        guard isIncognitoOpen || activeSpaceID == Space.incognitoID || spaceBeforeIncognito != nil else { return self }
        var saved = self
        saved.tabs.removeAll(where: \.isIncognito)
        if saved.activeSpaceID == Space.incognitoID {
            saved.activeSpaceID = spaceOutsideIncognito
            saved.activeTabID = saved.tabs(inSpace: saved.activeSpaceID).first?.id
        }
        saved.spaceBeforeIncognito = nil
        return saved
    }

    /// Incognito's last tab closed: if it was the active Space, back to the one before it, on the tab
    /// most recently viewed there.
    mutating func leaveIncognitoIfEmpty() {
        guard !isIncognitoOpen, activeSpaceID == Space.incognitoID else { return }
        activeSpaceID = spaceOutsideIncognito
        activeTabID = tabs(inSpace: activeSpaceID).first?.id
    }
}
