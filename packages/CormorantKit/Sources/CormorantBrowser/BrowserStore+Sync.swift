import CormorantCore
import CormorantSync
import Foundation

// MARK: - Sync
//
// The engine (`SyncEngine`, CormorantSync) does the syncing; this is where it meets the store. It
// reads the state only while the state may be saved (`canSave`), so an unreadable file that hasn't
// been started fresh is neither sent anywhere nor merged into.

extension BrowserStore {
    /// Whether this build and run can sync at all (Settings shows the switch only then).
    public var canSync: Bool { sync != nil }

    /// Settings' switch. Off forgets what this device knew of the cloud and leaves the cloud's records
    /// and this device's tabs as they are.
    public func setSync(on: Bool) {
        settings.syncsWithICloud = on
        if on {
            startSyncIfOn()
        } else {
            sync?.stop()
        }
    }

    /// The cloud said something changed (a silent push), or the app came to the front.
    public func syncNow() {
        guard let sync, sync.isOn else { return }
        Task { await sync.sync() }
    }

    /// As `syncNow`, returning when the round is done: for a push's completion handler.
    public func syncAndWait() async {
        guard let sync, sync.isOn else { return }
        await sync.sync()
    }

    /// `fresh`: the state was started over (Start Fresh), so nothing the last session knew is read
    /// back into it, and this device joins as a new one.
    func startSyncIfOn(fresh: Bool = false) {
        guard let sync, settings.syncsWithICloud, canSave else { return }
        sharedSeenBySync = state.shared
        if sync.isOn {
            if fresh { sync.stateWasReset() }
        } else {
            sync.start(fresh: fresh)
        }
    }

    /// The app came to the front. With sync on, idle tabs are archived only after a round that worked:
    /// until the other devices' news is in, a tab used elsewhere all day looks idle here, and
    /// archiving it would close it there too. Offline, they wait for the next time.
    func syncThenArchive() {
        guard let sync, sync.isOn else { return }
        Task {
            await sync.sync()
            if sync.isOn, sync.state == .idle { archiveIdleTabs() }
        }
    }

    /// The app may be suspended: what's decided goes out first.
    func finishSync() {
        guard let sync, sync.isOn else { return }
        keepRunningForSync(until: Task { await sync.finish() })
    }

    /// Every change to the state passes here (with each save asked for): sync is told what the shared
    /// part was and is, and reads removals from the difference.
    func tellSyncWhatChanged() {
        guard let sync, sync.isOn, canSave else { return }
        let shared = state.shared
        guard shared != sharedSeenBySync else { return }
        sync.localDidChange(from: sharedSeenBySync, to: shared)
        sharedSeenBySync = shared
    }

    /// The engine's merge of the other devices' changes. A tab whose page changed elsewhere loads it
    /// when next shown, its own back/forward history gone. Except the one being looked at: it stays
    /// on its page until it's out of sight (`followSyncOutOfSight`).
    func applyFromSync(_ shared: BrowserState.Shared) {
        guard canSave else { return }
        let before = Dictionary(state.tabs.map { ($0.id, $0.url) }) { first, _ in first }
        setSharedState(shared)
        var moved = Set<UUID>()
        for tab in state.tabs {
            guard let old = before[tab.id], old != tab.url, hasPage(tab.id) else { continue }
            if tab.id == state.activeTabID, !isInBackground {
                if tabKeptOnItsPage?.tabID != tab.id { tabKeptOnItsPage = (tab.id, old) }
            } else {
                moved.insert(tab.id)
            }
        }
        loadFromState(moved)
        // Not a change of this device's to send.
        sharedSeenBySync = state.shared
        refreshAfterSync()
    }

    /// The tab kept on its page while it was looked at is out of sight now (another tab is in front,
    /// or the app isn't): it goes to the page the other device took it to.
    func followSyncOutOfSight() {
        guard let kept = tabKeptOnItsPage, kept.tabID != state.activeTabID || isInBackground else { return }
        tabKeptOnItsPage = nil
        guard let tab = state.tab(kept.tabID), tab.url != kept.url else { return }
        loadFromState([kept.tabID])
    }
}
