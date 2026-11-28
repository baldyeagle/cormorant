import CormorantCore
import Foundation
import os

/// The work of syncing, off the main thread: it owns the session (what this device knows of the
/// cloud), builds and compares the records, merges, seals, talks to the cloud and writes the session
/// file. `SyncEngine` gives it copies of the state and applies what it merges.
///
/// It works on a copy of the state, which may have changed by the time a merge is done. So a merge
/// is made on a copy of the session too, and only kept if the engine could apply it to the very state
/// it was made from (`merge`); otherwise it's made again from the state as it is now.
actor SyncWorker {
    /// How a round ended. `synced`: with nothing left to send.
    struct Outcome: Sendable {
        var state: SyncState
        var synced = false
    }

    private let cloud: any SyncCloud
    private let keyStore: any SyncKeyStore
    private let fileURL: URL?
    /// Returns once the state, as it is now, is on disk. The session is only written after it: a
    /// session that knows of a merge the saved state doesn't have would, after a crash, take the old
    /// state for the user's own change and send it back. The other way round only costs a fetch.
    private let stateSaved: (@MainActor () async -> Void)?

    private var session = SyncSession()
    private var savedSession: SyncSession?
    private var isRunning = false
    /// Goes up whenever the session is replaced (on, off, a reset): a round that was out meanwhile
    /// stops, its work being for a session that's gone.
    private var epoch = 0
    /// The session was just read back: what the state lost without being seen to remove it is restored
    /// from it at the next round.
    private var restoresMissing = false
    private var activeKey: SyncKey?
    /// The changes noted while a merge is being made, to note again in the session it leaves.
    private var notedDuringMerge: [(old: BrowserState.Shared, new: BrowserState.Shared)]?
    private var writes: Task<Void, Never>?
    /// Runs between the engine applying a merge and the session taking it: tests make a change there.
    private var afterApplyForTesting: (@Sendable () async -> Void)?
    func setAfterApplyForTesting(_ hook: (@Sendable () async -> Void)?) { afterApplyForTesting = hook }
    private static let log = os.Logger(subsystem: "dev.baldyeagle.cormorant", category: "sync")

    init(cloud: any SyncCloud, keyStore: any SyncKeyStore, fileURL: URL?, stateSaved: (@MainActor () async -> Void)?) {
        self.cloud = cloud
        self.keyStore = keyStore
        self.fileURL = fileURL
        self.stateSaved = stateSaved
    }

    // MARK: What the engine tells it, in the order it happened

    /// Sync was turned on: what the last session knew is read back. Not when `fresh` (the state was
    /// started over): the last session may be long out of date, and nothing comes back from it.
    func start(fresh: Bool) async {
        // Turned off a moment ago: the old session's file goes first, or it would be read back here.
        await finishWrites()
        if !fresh, let fileURL, let data = try? Data(contentsOf: fileURL) {
            // A session that doesn't read is started over: the first round fetches everything, and
            // nothing is deleted on the strength of a session that isn't there.
            session = (try? JSONDecoder().decode(SyncSession.self, from: data)) ?? SyncSession()
        } else {
            session = SyncSession()
        }
        savedSession = fresh ? nil : session
        activeKey = nil
        isRunning = true
        restoresMissing = true
        epoch += 1
        save()
    }

    /// Sync was turned off: the session is forgotten, and its file goes.
    func stop() {
        isRunning = false
        epoch += 1
        session = SyncSession()
        savedSession = nil
        activeKey = nil
        restoresMissing = false
        let previous = writes
        writes = Task.detached { [fileURL] in
            await previous?.value
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    /// The state was started over: the session goes too.
    func reset() {
        guard isRunning else { return }
        session = SyncSession()
        activeKey = nil
        restoresMissing = false
        epoch += 1
        save()
    }

    /// The state went from `old` to `new`. Returns whether what's waiting to be sent is minor
    /// (`SyncLedger.Changes.isMinor`), nil when sync is off.
    func note(from old: BrowserState.Shared, to new: BrowserState.Shared) -> Bool? {
        guard isRunning else { return nil }
        if old != new {
            let deletes = session.ledger.pendingDeletes
            session.ledger.noteLocalChange(from: old, to: new)
            notedDuringMerge?.append((old, new))
            // A removal is only known from having been seen: on disk at once, so a quit doesn't undo it.
            if session.ledger.pendingDeletes != deletes { save() }
        }
        return session.ledger.pendingChanges(local: new).isMinor
    }

    func pendingIsMinor(_ shared: BrowserState.Shared) -> Bool {
        session.ledger.pendingChanges(local: shared).isMinor
    }

    /// Returns once every session write asked for so far is done.
    func finishWrites() async {
        while let current = writes {
            await current.value
            if writes == current { break }
        }
    }

    // MARK: A round

    /// Fetch, merge, send; again while the cloud refused something. Nil when sync was turned off or
    /// the session replaced meanwhile: nothing to report.
    func round(host: SyncEngine) async -> Outcome? {
        let epoch = epoch
        guard isRunning else { return nil }
        do {
            if restoresMissing {
                guard try await merge(host: host, epoch: epoch, { session, shared in
                    session.ledger.restoringMissing(in: shared)
                }) else { return nil }
                restoresMissing = false
                save()
            }
            for _ in 0..<8 {
                let changes: SyncCloudChanges
                do {
                    changes = try await cloud.fetch(since: session.token)
                } catch SyncCloudError.tokenExpired {
                    guard epoch == self.epoch else { return nil }
                    session.token = nil
                    continue
                }
                guard epoch == self.epoch else { return nil }
                let keys = try keyStore.keys()
                if changes.isEverything, changes.records.isEmpty { activeKey = nil }
                guard try await merge(host: host, epoch: epoch, { session, shared in
                    try session.take(changes, keys: keys, local: shared)
                }) else { return nil }
                save()

                guard let current = await snapshot(host: host, epoch: epoch) else { return nil }
                guard !session.ledger.pendingChanges(local: current).isEmpty else {
                    return Outcome(state: .idle, synced: true)
                }
                guard let key = try await resolveKey(epoch: epoch) else {
                    return epoch == self.epoch ? Outcome(state: .waitingForKey) : nil
                }
                guard let sending = await snapshot(host: host, epoch: epoch) else { return nil }
                let outgoing = try session.outgoing(local: sending, key: key)
                guard !outgoing.isEmpty else {
                    // What's pending can't be sent: records this build can't read.
                    return Outcome(state: .idle, synced: true)
                }
                let result = try await cloud.send(saves: outgoing.saves, deletes: outgoing.deletes)
                guard epoch == self.epoch else { return nil }
                let keysNow = try keyStore.keys()
                guard try await merge(host: host, epoch: epoch, { session, shared in
                    try session.took(result, of: outgoing, keys: keysNow, local: shared)
                }) else { return nil }
                save()
            }
            return Outcome(state: .failed(Self.unfinished))
        } catch SyncCipherError.missingKey {
            return Outcome(state: .waitingForKey)
        } catch SyncCloudError.noAccount {
            return Outcome(state: .noAccount)
        } catch SyncCloudError.failed(let message) {
            return Outcome(state: .failed(message))
        } catch {
            Self.log.error("Sync failed: \(String(describing: error), privacy: .public)")
            return Outcome(state: .failed(error.localizedDescription))
        }
    }

    private static let unfinished = "Couldn't finish syncing. It will try again."

    /// The state as it is now, once every change made to it up to now has been noted here. Nil when
    /// it can't be synced any more, or the session was replaced.
    private func snapshot(host: SyncEngine, epoch: Int) async -> BrowserState.Shared? {
        guard let (shared, noted) = await host.snapshot() else { return nil }
        await noted?.value
        return epoch == self.epoch ? shared : nil
    }

    /// Makes a merge (`step`: the session and the state in, the merged state out) and has the engine
    /// apply it. The state may have changed while it was made: then the merge and what it did to the
    /// session are dropped, and it's made again from the state as it is now. After a few of those
    /// (a page that keeps changing its title) it's made on the main actor, where nothing can change
    /// meanwhile. False when the state can't be synced any more, or the session was replaced.
    private func merge(host: SyncEngine, epoch: Int, _ step: @escaping Step) async throws -> Bool {
        defer { notedDuringMerge = nil }
        for pass in 0..<20 {
            guard let (shared, noted) = await host.snapshot() else { return false }
            await noted?.value
            guard epoch == self.epoch else { return false }
            // From here on: `note` runs while this waits on the engine, and changes the session this
            // one is about to replace.
            notedDuringMerge = []
            var merged = session
            if pass < Self.passesOffMain {
                let result = try step(&merged, shared)
                let applied = await host.apply(result, ifStill: shared)
                await afterApplyForTesting?()
                guard epoch == self.epoch, let applied else { return false }
                guard applied else { continue }
            } else {
                switch try await host.merge(merged, ifLastTold: noted, step) {
                case .off: return false
                case .changed: continue
                case .done(let session): merged = session
                }
                guard epoch == self.epoch else { return false }
            }
            for change in notedDuringMerge ?? [] { merged.ledger.noteLocalChange(from: change.old, to: change.new) }
            session = merged
            return true
        }
        throw SyncCloudError.failed(Self.unfinished)
    }

    typealias Step = @Sendable (inout SyncSession, BrowserState.Shared) throws -> BrowserState.Shared
    private static let passesOffMain = 3

    /// The key to encrypt with: the one the cloud names, if it's in the keychain. With none named,
    /// this device's (made now if it has none) is put forward, and the first device to do so wins.
    /// Nil while the named key hasn't reached this device.
    private func resolveKey(epoch: Int) async throws -> SyncKey? {
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
        guard epoch == self.epoch else { return nil }
        activeKey = keys.first { $0.id == named }
        return activeKey
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
