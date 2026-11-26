import CormorantCore
import Foundation
import Observation
import os

/// Keeps a device's shared state and the cloud's the same. The app gives it the state (`local`), a way
/// to change it (`apply`), and every change made to it (`localDidChange`); the engine fetches, merges
/// and sends, one round at a time.
///
/// On the main actor with the state: a merge reads the state and applies the result without anything
/// changing in between, and only the cloud calls are awaited.
@MainActor
@Observable
public final class SyncEngine {
    public private(set) var state: SyncState = .disabled
    /// When a round last finished with nothing left to send.
    public private(set) var lastSyncedAt: Date?

    @ObservationIgnored private let cloud: any SyncCloud
    @ObservationIgnored private let keyStore: any SyncKeyStore
    @ObservationIgnored private let fileURL: URL?
    /// The state's shared part, or nil while it mustn't be synced: not loaded, or unreadable and not
    /// yet started fresh.
    @ObservationIgnored private let local: () -> BrowserState.Shared?
    @ObservationIgnored private let apply: (BrowserState.Shared) -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let minorDebounce: Duration
    /// Returns once the state, as it is now, is on disk. The session is only written after it: a
    /// session that knows of a merge the saved state doesn't have would, after a crash, take the old
    /// state for the user's own change and send it back. The other way round only costs a fetch.
    @ObservationIgnored private let stateSaved: (@MainActor () async -> Void)?

    @ObservationIgnored private var session = SyncSession()
    @ObservationIgnored private var isRunning = false
    /// The engine is changing the state itself: not a change to send, or to read a removal from.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var activeKey: SyncKey?
    @ObservationIgnored private var round: Task<Void, Never>?
    @ObservationIgnored private var wantsAnotherRound = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var scheduledFor: ContinuousClock.Instant?
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var savedSession: SyncSession?
    nonisolated private static let log = os.Logger(subsystem: "dev.baldyeagle.cormorant", category: "sync")

    /// `fileURL` is where the session is kept (nil: in memory only, for tests). `debounce` is how long
    /// after a change a round starts, so a burst of changes is one send; `minorDebounce` when the only
    /// changes are tabs' titles and last-viewed times, which pages make by themselves all the time.
    public init(cloud: any SyncCloud, keyStore: any SyncKeyStore, fileURL: URL?, debounce: Duration = .seconds(2),
                minorDebounce: Duration = .seconds(60), stateSaved: (@MainActor () async -> Void)? = nil,
                local: @escaping () -> BrowserState.Shared?, apply: @escaping (BrowserState.Shared) -> Void) {
        self.minorDebounce = minorDebounce
        self.stateSaved = stateSaved
        self.cloud = cloud
        self.keyStore = keyStore
        self.fileURL = fileURL
        self.debounce = debounce
        self.local = local
        self.apply = apply
    }

    public var isOn: Bool { isRunning }

    /// Turns sync on: what the last session knew is read back, anything the state lost without being
    /// seen to remove it is restored from it, and a round starts. Does nothing while the state can't
    /// be synced (`local` is nil): call it again once it can.
    ///
    /// `fresh` is for a state that was started over (Start Fresh): the last session is not read, so
    /// nothing comes back from it (it may be long out of date), and the device merges with the cloud
    /// as a new one would, deleting nothing there.
    public func start(fresh: Bool = false) {
        guard !isRunning, let shared = local() else { return }
        if !fresh, let fileURL, let data = try? Data(contentsOf: fileURL) {
            // A session that doesn't read is started over: the first round fetches everything, and
            // nothing is deleted on the strength of a session that isn't there.
            session = (try? JSONDecoder().decode(SyncSession.self, from: data)) ?? SyncSession()
        } else {
            session = SyncSession()
        }
        savedSession = fresh ? nil : session
        isRunning = true
        state = .idle
        change(to: session.ledger.restoringMissing(in: shared), from: shared)
        save()
        syncSoon(after: .zero)
    }

    /// Turns sync off and forgets the session. The cloud's records stay; turning it back on merges
    /// with them as a new device would.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        scheduled?.cancel()
        scheduledFor = nil
        activeKey = nil
        session = SyncSession()
        savedSession = nil
        state = .disabled
        lastSyncedAt = nil
        let previous = writes
        writes = Task.detached { [fileURL] in
            await previous?.value
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    /// The state was started over (Start Fresh): the session goes too, so this device merges with the
    /// cloud as a new one would, deleting nothing there.
    public func stateWasReset() {
        guard isRunning else { return }
        session = SyncSession()
        activeKey = nil
        save()
        syncSoon(after: .zero)
    }

    /// The state changed. Call for every change, with the shared part before and after: what's gone
    /// between the two was removed on this device, and is deleted from the cloud.
    public func localDidChange(from old: BrowserState.Shared, to new: BrowserState.Shared) {
        guard isRunning, !isApplying, old != new else { return }
        let deletes = session.ledger.pendingDeletes
        session.ledger.noteLocalChange(from: old, to: new)
        // A removal is only known from having been seen: on disk at once, so a quit doesn't undo it.
        if session.ledger.pendingDeletes != deletes { save() }
        syncSoon(after: session.ledger.pendingChanges(local: new).isMinor ? minorDebounce : debounce)
    }

    /// A round now (the app came to the front, or the cloud said something changed), or right after
    /// the one that's running. Returns when it's done.
    public func sync() async {
        guard isRunning else { return }
        // Not `cancel()`: this may be the scheduled task itself.
        scheduledFor = nil
        if let round {
            wantsAnotherRound = true
            await round.value
            return
        }
        let task = Task {
            repeat {
                wantsAnotherRound = false
                await runRound()
            } while wantsAnotherRound && isRunning
            round = nil
        }
        round = task
        await task.value
    }

    /// Everything decided so far is sent and on disk. For when the app is about to be suspended.
    public func finish() async {
        if isRunning { await sync() }
        await writes?.value
    }

    /// A round after `delay`, unless one is due sooner. Asking again doesn't push it back: a page
    /// that changes its title every second can't keep sync from ever running.
    /// Whether what `shared` has to send is only tabs' titles and last-viewed times. For tests.
    func pendingIsMinor(_ shared: BrowserState.Shared) -> Bool {
        session.ledger.pendingChanges(local: shared).isMinor
    }

    private func syncSoon(after delay: Duration) {
        let due = ContinuousClock.now + delay
        if let scheduledFor, scheduledFor <= due { return }
        scheduled?.cancel()
        scheduledFor = due
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, scheduledFor == due else { return }
            await sync()
        }
    }

    private func runRound() async {
        guard local() != nil else { return }
        report(.syncing)
        do {
            // Rounds of fetch, merge, send; again while the cloud refused something.
            for _ in 0..<8 {
                let token = session.token
                let changes: SyncCloudChanges
                do {
                    changes = try await cloud.fetch(since: token)
                } catch SyncCloudError.tokenExpired {
                    session.token = nil
                    continue
                }
                guard isRunning, let shared = local() else { return }
                // Something else moved the session on (a reset) while the fetch was out: start over.
                guard session.token == token else { continue }
                let keys = try keyStore.keys()
                if changes.isEverything, changes.records.isEmpty { activeKey = nil }
                change(to: try session.take(changes, keys: keys, local: shared), from: shared)
                save()

                guard let current = local() else { return }
                guard !session.ledger.pendingChanges(local: current).isEmpty else {
                    lastSyncedAt = .now
                    report(.idle)
                    return
                }
                guard let key = try await resolveKey() else {
                    report(.waitingForKey)
                    return
                }
                guard isRunning, let sending = local() else { return }
                let outgoing = try session.outgoing(local: sending, key: key)
                guard !outgoing.isEmpty else {
                    // What's pending can't be sent: records this build can't read.
                    lastSyncedAt = .now
                    report(.idle)
                    return
                }
                let result = try await cloud.send(saves: outgoing.saves, deletes: outgoing.deletes)
                guard isRunning, let after = local() else { return }
                change(to: try session.took(result, of: outgoing, keys: try keyStore.keys(), local: after), from: after)
                save()
            }
            report(.failed("Couldn't finish syncing. It will try again."))
        } catch SyncCipherError.missingKey {
            report(.waitingForKey)
        } catch SyncCloudError.noAccount {
            report(.noAccount)
        } catch SyncCloudError.failed(let message) {
            report(.failed(message))
        } catch {
            Self.log.error("Sync failed: \(String(describing: error), privacy: .public)")
            report(.failed(error.localizedDescription))
        }
    }

    /// Not once sync was turned off while the round was out: Settings would show it under the switch.
    private func report(_ new: SyncState) {
        if isRunning { state = new }
    }

    /// The key to encrypt with: the one the cloud names, if it's in the keychain. With none named,
    /// this device's (made now if it has none) is put forward, and the first device to do so wins.
    /// Nil while the named key hasn't reached this device.
    private func resolveKey() async throws -> SyncKey? {
        if let activeKey { return activeKey }
        var keys = try keyStore.keys().sorted { $0.id < $1.id }
        var named = try await cloud.keyID()
        if named == nil {
            let mine: SyncKey
            if let existing = keys.first {
                mine = existing
            } else {
                mine = SyncKey()
                try keyStore.add(mine)
                keys.append(mine)
            }
            named = try await cloud.announce(keyID: mine.id)
        }
        activeKey = keys.first { $0.id == named }
        return activeKey
    }

    private func change(to shared: BrowserState.Shared, from old: BrowserState.Shared) {
        guard shared != old else { return }
        isApplying = true
        apply(shared)
        isApplying = false
    }

    private func save() {
        guard let fileURL, session != savedSession else { return }
        savedSession = session
        let previous = writes
        writes = Task.detached { [session, stateSaved] in
            await previous?.value
            await stateSaved?()
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
            } catch {
                Self.log.error("Saving the sync session failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
