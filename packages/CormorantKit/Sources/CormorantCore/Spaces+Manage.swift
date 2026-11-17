import Foundation

// MARK: - Managing Spaces (New Space, Edit Space)

extension BrowserState {
    /// A look for a new Space: the first icon and the first color no Space (archived ones included)
    /// uses yet, each falling back to the first of its kind once all are taken. Beside a Home left as
    /// it came, that's a briefcase on indigo.
    public var suggestedNewSpaceLook: (icon: SpaceIcon, color: Swatch) {
        let icons = Set(spaces.map(\.icon)), colors = Set(spaces.map(\.color))
        return (SpaceIcon.allCases.first { !icons.contains($0) } ?? SpaceIcon.allCases[0],
                Swatch.allCases.first { !colors.contains($0) } ?? Swatch.allCases[0])
    }

    /// Closed tabs that `restore(archivedID:)` would reopen in `spaceID`, the active Space, without
    /// switching away: those closed there, and those whose own Space is gone or archived (they reopen
    /// in the active Space).
    /// The search panel lists these, so choosing one never takes you to another Space.
    public func archived(reopeningIn spaceID: UUID) -> [ArchivedTab] {
        archived.filter { entry in
            entry.spaceID == spaceID || space(entry.spaceID)?.isArchived != false
        }
    }

    /// The tabs in `spaceID` that `policy` (the Space's own when nil) would archive at `now`, as
    /// `runArchive` decides: never the active tab, and none in an archived or unknown Space. Blank tabs
    /// are included, as there (the archiver drops them). Edit Space uses it to say what a shorter
    /// archive time will take at the next foreground.
    public func tabsDue(inSpace spaceID: UUID, policy: ArchivePolicy? = nil, now: Date = .now) -> [Tab] {
        guard let space = space(spaceID), !space.isArchived else { return [] }
        return (policy ?? space.archivePolicy)
            .tabsDue(in: tabs.filter { $0.spaceID == spaceID }, activeTabID: activeTabID, now: now)
    }
}

extension Space {
    /// Edit Space's Archive confirmation: what archiving the Space named `name`, with `tabCount` open
    /// tabs, does with it and them, and how it comes back.
    public static func archiveConfirmation(name: String, tabCount: Int) -> String {
        let kept = switch tabCount {
        case 0: "It has no open tabs."
        case 1: "Its tab is kept, and doesn't archive while the Space is away."
        default: "Its \(tabCount) tabs are kept, and don't archive while the Space is away."
        }
        return "\(kept) \(name) leaves the Spaces you switch between until you restore it from Archived in Spaces."
    }

    /// The Delete confirmation, in Edit Space and for an archived Space in Manage Spaces: where a Space's
    /// `tabCount` open tabs go.
    public static func deleteConfirmation(tabCount: Int) -> String {
        let moved = switch tabCount {
        case 0: "It has no open tabs."
        case 1: "Its tab goes to the tab archive, where you can search for it and reopen it."
        default: "Its \(tabCount) tabs go to the tab archive, where you can search for them and reopen them."
        }
        return "\(moved) The Space and its settings are gone."
    }
}

// MARK: - Profiles (Manage Spaces' Profiles section, New and Edit Profile)

extension BrowserState {
    /// The profile the active Space uses: whose website data its tabs have, and whose history the
    /// search panel suggests from.
    public var activeProfile: Profile { profile(forSpace: activeSpaceID) }

    /// A color for a new profile: the first no profile uses yet, after the default profile's blue,
    /// falling back to the first once all are taken.
    public var suggestedNewProfileColor: Swatch {
        let colors = Set(profiles.map(\.color))
        return Swatch.allCases.first { !colors.contains($0) } ?? Swatch.allCases[0]
    }

    /// Profiles in the order Manage Spaces lists them: the default first, then by when they were made.
    public var profilesInOrder: [Profile] {
        profiles.filter(\.isDefault) + profiles.filter { !$0.isDefault }.sorted { $0.createdAt < $1.createdAt }
    }
}
