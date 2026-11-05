import CormorantCore
import Foundation

/// Settings' Archive Idle Tabs: when tabs nobody has looked at move to the tab archive. Each Space
/// has its own time (`Space.archivePolicy`, also set by Edit Space); Spaces themselves never archive
/// on their own. The archiver runs when the app comes back (`didBecomeActive`), never from here.
extension BrowserStore {
    /// Off in every Space at once, or back on with each Space's time as it was (see
    /// `BrowserState.stopArchivingIdleTabs` / `resumeArchivingIdleTabs`). Archives nothing.
    func setArchivesIdleTabs(_ on: Bool) {
        changeState { on ? $0.resumeArchivingIdleTabs() : $0.stopArchivingIdleTabs() }
    }

    /// The Space's idle time, as Edit Space's Archive Idle Tabs After picker sets it.
    func setArchivePolicy(_ policy: ArchivePolicy, forSpace spaceID: UUID) {
        changeState { $0.updateSpace(spaceID) { $0.archivePolicy = policy } }
    }
}

#if DEBUG
extension BrowserStore {
    /// UI tests only (`-uiTesting`), applied to the loaded tabs before anything archives:
    /// - `-uiTestingArchiveSpaces "Work:43200,Reading:off"` adds those Spaces, each with its idle time in
    ///   seconds or `off` (24 hours when left out), unless there are Spaces besides Home already (a
    ///   relaunch of the same session).
    /// - `-uiTestingIdleFor <seconds>` makes every open tab last viewed that much earlier, as if the app
    ///   had been away that long. The active tab is never archived, and counts as viewed on arrival.
    static func uiTestingLaunchState(_ state: BrowserState) -> BrowserState {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTesting") else { return state }
        var state = state
        let defaults = UserDefaults.standard
        if let spaces = defaults.string(forKey: "uiTestingArchiveSpaces"), state.spaces.count == 1 {
            for entry in spaces.split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                let space = state.addSpace(name: parts[0])
                let policy: ArchivePolicy = switch parts.count > 1 ? parts[1] : nil {
                case "off": .off
                case let seconds?: TimeInterval(seconds).map { ArchivePolicy(interval: $0) } ?? .oneDay
                case nil: .oneDay
                }
                state.updateSpace(space.id) { $0.archivePolicy = policy }
            }
        }
        let idle = defaults.double(forKey: "uiTestingIdleFor")
        if idle > 0 {
            for tab in state.tabs { state.markViewed(tabID: tab.id, now: tab.lastViewedAt - idle) }
        }
        return state
    }
}
#endif
