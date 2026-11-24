import CormorantCore
import Foundation
import Observation

/// The Space a Focus filter sends links from other apps to, while a Focus with Cormorant's filter is
/// on: set by the system through `SpaceFocusFilter`, read by `BrowserStore` whenever a link arrives,
/// and by Edit Space. The app learns only that its filter is on and which Space it names, not which
/// Focus turned it on. Kept in the app group's defaults (`FocusFilterSpace`), so it survives the app
/// being killed; the system calls the filter again when the Focus ends.
@MainActor
@Observable
final class FocusFilterSettings {
    /// The filter's Space; nil while no Focus with the filter is on. May name a Space since deleted or
    /// archived: `BrowserState.destinationForLink` then falls back to the Space last used.
    private(set) var spaceID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let systemFilterSpace: (@MainActor () async -> UUID??)?
    /// Bumped by each `set`, so an answer to `refresh()` asked for before the system last set the
    /// filter (a Focus starting meanwhile) is dropped rather than undoing it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var asking: Task<Void, Never>?

    /// - Parameter systemFilterSpace: asks the system for the Space of the filter in force: nil if it
    ///   couldn't say, `.some(nil)` for none. Nil never asks (UI tests set the filter themselves).
    init(defaults: UserDefaults, systemFilterSpace: (@MainActor () async -> UUID??)?) {
        self.defaults = defaults
        self.systemFilterSpace = systemFilterSpace
        spaceID = FocusFilterSpace.read(from: defaults)
    }

    func set(_ spaceID: UUID?) {
        generation += 1
        FocusFilterSpace.write(spaceID, to: defaults)
        if self.spaceID != spaceID { self.spaceID = spaceID }
    }

    /// On launch and foreground: what was stored (the system may have called the filter in another
    /// launch), then, once the system answers, the filter actually in force, in case a call was missed.
    /// One question at a time; an answer the system has overtaken by setting the filter is dropped.
    func refresh() {
        let stored = FocusFilterSpace.read(from: defaults)
        if spaceID != stored { spaceID = stored }
        guard let systemFilterSpace else { return }
        asking?.cancel()
        let asked = generation
        asking = Task {
            guard let current = await systemFilterSpace(), !Task.isCancelled, generation == asked
            else { return }
            set(current)
        }
    }
}
