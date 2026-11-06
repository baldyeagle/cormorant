import Foundation

// MARK: - The times offered

extension ArchivePolicy {
    public static let sevenDays = ArchivePolicy(interval: 7 * 24 * 60 * 60)
    public static let thirtyDays = ArchivePolicy(interval: 30 * 24 * 60 * 60)

    /// The choices Settings and Edit Space offer, in order: Arc's four times, then Off. A saved time
    /// that isn't one of these (a newer build's) is kept, and shown as its own choice.
    public static let offered: [ArchivePolicy] = [.twelveHours, .oneDay, .sevenDays, .thirtyDays, .off]

    /// How the choice reads: "12 Hours", "24 Hours", "7 Days", "30 Days" or "Off". Any other time reads
    /// the same way, in whole days from 2 days up when it's a whole number of them, else in hours (to
    /// the nearest, at least 1): "3 Days", "36 Hours"; "About 24 Hours" where that would match an
    /// offered time's. Not localized, like the rest of the app.
    public var label: String {
        if let label = Self.offeredLabel(self) { return label }
        // Never the same as an offered time's, which it would be confused with in the same list.
        let label = Self.label(seconds: interval ?? 0)
        return Self.offered.contains { Self.offeredLabel($0) == label } ? "About \(label)" : label
    }

    private static func offeredLabel(_ policy: ArchivePolicy) -> String? {
        switch policy {
        case .twelveHours: "12 Hours"
        case .oneDay: "24 Hours"
        case .sevenDays: "7 Days"
        case .thirtyDays: "30 Days"
        case .off: "Off"
        default: nil
        }
    }

    private static func label(seconds: TimeInterval) -> String {
        // Clamped so the conversion to Int can't trap, whatever a value built in code holds.
        let hours = Int(min(max((seconds / 3600).rounded(), 1), longest / 3600))
        if hours >= 48, hours.isMultiple(of: 24) { return "\(hours / 24) Days" }
        return hours == 1 ? "1 Hour" : "\(hours) Hours"
    }

    /// `offered`, plus `saved` in its place by length if it isn't one of them, so a time this build
    /// doesn't offer stays chosen until another is.
    public static func choices(keeping saved: ArchivePolicy) -> [ArchivePolicy] {
        var choices = offered
        guard !choices.contains(saved), let interval = saved.interval else { return choices }
        choices.insert(saved, at: choices.firstIndex { ($0.interval ?? .infinity) > interval } ?? choices.endIndex)
        return choices
    }
}

// MARK: - Archive Idle Tabs (Settings)

extension BrowserState {
    /// Whether any Space you can switch to moves idle tabs to the tab archive: Settings' Archive Idle
    /// Tabs switch. Only tabs archive on their own; a Space is archived only by `archiveSpace`.
    public var archivesIdleTabs: Bool {
        switchableSpaces.contains { $0.archivePolicy.interval != nil }
    }

    /// Turns auto-archive off in every Space, archived ones included (so restoring one doesn't start
    /// it again). Each Space's time is kept in `archivePolicyBeforeOff` for `resumeArchivingIdleTabs`;
    /// a Space already off keeps whatever it remembered. Archives nothing, and leaves tabs' idle
    /// time alone.
    public mutating func stopArchivingIdleTabs() {
        for index in spaces.indices where spaces[index].archivePolicy.interval != nil {
            spaces[index].archivePolicyBeforeOff = spaces[index].archivePolicy
            spaces[index].archivePolicy = .off
        }
    }

    /// Undoes `stopArchivingIdleTabs`: each Space that's off gets back the time it had (a Space that
    /// was off on its own stays off), and Spaces given a time since keep it. If that leaves every Space
    /// you can switch to off, they all get 24 hours: the switch was turned on. Tabs already idle longer
    /// than their Space's time move the next time `runArchive` runs (see `tabsDue(inSpace:policy:now:)`).
    public mutating func resumeArchivingIdleTabs() {
        for index in spaces.indices {
            if spaces[index].archivePolicy.interval == nil, let before = spaces[index].archivePolicyBeforeOff {
                spaces[index].archivePolicy = before
            }
            spaces[index].archivePolicyBeforeOff = nil
        }
        guard !archivesIdleTabs else { return }
        for index in spaces.indices where !spaces[index].isArchived {
            spaces[index].archivePolicy = .oneDay
        }
    }
}
