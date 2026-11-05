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
