import Foundation

// MARK: - Edit Space's Focus group (the Focus filter, as a Space's editor shows it)

/// What Edit Space's Focus group says: whether a Focus filter sends links from other apps to the Space
/// now (`isOn`), on its row, and in its footer what happens when the Focus ends, or how to set one up
/// (that's in iOS Settings). The app knows its filter is on and which Space it names, not which Focus
/// it belongs to, so it doesn't say.
public struct FocusFilterGroup: Sendable, Equatable {
    public let isOn: Bool
    public let status: String
    public let footer: String

    public init(isOn: Bool, status: String, footer: String) {
        self.isOn = isOn
        self.status = status
        self.footer = footer
    }
}

extension BrowserState {
    /// Edit Space's Focus group for the saved Space `spaceID`, named `name` in the editor's field, while
    /// the Focus filter names `focusSpace` (nil: no Focus with the filter is on). Nil where Edit Space
    /// has none: only one Space, or the Space archived or gone.
    public func focusFilterGroup(editing spaceID: UUID, named name: String, focusSpace: UUID?) -> FocusFilterGroup? {
        guard switchableSpaces.count > 1, let saved = space(spaceID), !saved.isArchived, !saved.isIncognito else { return nil }
        return focusSpace == spaceID
            ? FocusFilterGroup(isOn: true, status: "On now: links from other apps open in \(name)",
                               footer: "When the Focus ends, links open in the last Space you used.")
            : FocusFilterGroup(isOn: false, status: "Off",
                               footer: "To open links from other apps in \(name) during a Focus, go to Settings › Focus, choose a Focus, then Add Filter › Cormorant › \(saved.name).")
    }
}
