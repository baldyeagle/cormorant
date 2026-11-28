import CormorantCore
import Foundation
import Observation

/// Keeps a device's shared state and the cloud's the same. The app gives it the state (`local`), a way
/// to change it (`apply`), and every change made to it (`localDidChange`); the engine fetches, merges
/// and sends, one round at a time.
///
/// It's on the main actor with the state, and does next to nothing there: it hands copies of the
/// state to `SyncWorker`, which does the work off the main thread, and applies what the worker merged,
/// if the state is still the one the merge was made from (`apply(_:ifStill:)`).
@MainActor
@Observable
public final class SyncEngine {
    public private(set) var state: SyncState = .disabled
    /// When a round last finished with nothing left to send.
    public private(set) var lastSyncedAt: Date?

    @ObservationIgnored let worker: SyncWorker
    /// The state's shared part, or nil while it mustn't be synced: not loaded, or unreadable and not
    /// yet started fresh.
    @ObservationIgnored private let local: () -> BrowserState.Shared?
    @ObservationIgnored private let apply: (BrowserState.Shared) -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let minorDebounce: Duration

    @ObservationIgnored private var isRunning = false
    /// The engine is changing the state itself: not a change to send, or to read a removal from.
    @ObservationIgnored private var isApplying = false
    /// The last thing the worker was told (on, off, a reset, a change). Each waits for the one before,
    /// so the worker hears them in the order they happened.
    @ObservationIgnored private var told: Task<Void, Never>?
    @ObservationIgnored private var round: Task<Void, Never>?
    @ObservationIgnored private var wantsAnotherRound = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var scheduledFor: ContinuousClock.Instant?

    /// `fileURL` is where the session is kept (nil: in memory only, for tests). `debounce` is how long
    /// after a change a round starts, so a burst of changes is one send; `minorDebounce` when the only
    /// changes are tabs' titles and last-viewed times, which pages make by themselves all the time.
    /// `stateSaved` returns once the state, as it is now, is on disk: the session is only written
    /// after it.
    public init(cloud: any SyncCloud, keyStore: any SyncKeyStore, fileURL: URL?, debounce: Duration = .seconds(2),
                minorDebounce: Duration = .seconds(60), stateSaved: (@MainActor () async -> Void)? = nil,
                local: @escaping () -> BrowserState.Shared?, apply: @escaping (BrowserState.Shared) -> Void) {
        worker = SyncWorker(cloud: cloud, keyStore: keyStore, fileURL: fileURL, stateSaved: stateSaved)
        self.minorDebounce = minorDebounce
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
        guard !isRunning, local() != nil else { return }
        isRunning = true
        state = .idle
        tell { await $0.start(fresh: fresh) }
        syncSoon(after: .zero)
    }

    /// Turns sync off and forgets the session. The cloud's records stay; turning it back on merges
    /// with them as a new device would.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        scheduled?.cancel()
        scheduledFor = nil
        state = .disabled
        lastSyncedAt = nil
        tell { await $0.stop() }
    }

    /// The state was started over (Start Fresh): the session goes too, so this device merges with the
    /// cloud as a new one would, deleting nothing there.
    public func stateWasReset() {
        guard isRunning else { return }
        tell { await $0.reset() }
        syncSoon(after: .zero)
    }

    /// The state changed. Call for every change, with the shared part before and after: what's gone
    /// between the two was removed on this device, and is deleted from the cloud.
    public func localDidChange(from old: BrowserState.Shared, to new: BrowserState.Shared) {
        guard isRunning, !isApplying else { return }
        tell { [weak self] worker in
            guard let isMinor = await worker.note(from: old, to: new), let self, isRunning else { return }
            syncSoon(after: isMinor ? minorDebounce : debounce)
        }
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
        await told?.value
        await worker.finishWrites()
    }

    /// Whether what `shared` has to send is only tabs' titles and last-viewed times. For tests.
    func pendingIsMinor(_ shared: BrowserState.Shared) async -> Bool {
        await told?.value
        return await worker.pendingIsMinor(shared)
    }

    private func tell(_ what: @escaping @MainActor (SyncWorker) async -> Void) {
        let previous = told
        told = Task { [worker] in
            await previous?.value
            await what(worker)
        }
    }

    /// A round after `delay`, unless one is due sooner. Asking again doesn't push it back: a page
    /// that changes its title every second can't keep sync from ever running.
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
        // The worker has heard everything up to here before the round starts.
        await told?.value
        guard let outcome = await worker.round(host: self) else {
            // Stopped short (the state can't be read any more, or the session was replaced): not left
            // saying it's syncing.
            if state == .syncing { report(.idle) }
            return
        }
        if outcome.synced, isRunning { lastSyncedAt = .now }
        report(outcome.state)
    }

    /// Not once sync was turned off while the round was out: Settings would show it under the switch.
    private func report(_ new: SyncState) {
        if isRunning { state = new }
    }

    // MARK: For the worker

    /// The state now, and the last change the worker was told of: once that's noted, the worker knows
    /// of every change up to this state. Nil when sync is off or the state can't be synced.
    func snapshot() -> (shared: BrowserState.Shared, noted: Task<Void, Never>?)? {
        guard isRunning, let shared = local() else { return nil }
        return (shared, told)
    }

    /// Applies a merge made from `old`. False, changing nothing, when the state has changed since:
    /// the merge is made again. Nil when sync is off or the state can't be synced.
    func apply(_ shared: BrowserState.Shared, ifStill old: BrowserState.Shared) -> Bool? {
        guard isRunning, let current = local() else { return nil }
        guard current == old else { return false }
        if shared != old {
            isApplying = true
            apply(shared)
            isApplying = false
        }
        return true
    }

    enum Merged: Sendable {
        case off
        /// The state has changed since the worker last heard of it: it tries again.
        case changed
        case done(SyncSession)
    }

    /// Makes a merge here, on the state as it is, and applies it: nothing can change in between.
    /// `session` knows of every change up to `noted`; if more were told since, it doesn't know them
    /// all, and nothing is done.
    func merge(_ session: SyncSession, ifLastTold noted: Task<Void, Never>?, _ step: SyncWorker.Step) throws -> Merged {
        guard isRunning, let shared = local() else { return .off }
        guard told == noted else { return .changed }
        var session = session
        let result = try step(&session, shared)
        if result != shared {
            isApplying = true
            apply(result)
            isApplying = false
        }
        return .done(session)
    }
}
