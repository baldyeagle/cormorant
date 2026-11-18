import CormorantCore
import Foundation
import OSLog
import WebKit

/// Profiles: making, editing and deleting them, their website data, and erasing a deleted one's.
/// Which web view runs on which profile's data is decided from the state (`makeSession`,
/// `releaseSessionsOnOtherProfiles`); these only change the state and the stores.
extension BrowserStore {
    /// The active Space's profile, whose history the search panel suggests from.
    var activeProfileID: UUID { state.activeProfile.id }

    /// Adds a profile no Space uses yet. A blank name (after trimming) adds nothing.
    @discardableResult
    func createProfile(name: String, color: Swatch) -> Profile? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !name.isEmpty else { return nil }
        var profile: Profile?
        changeState { profile = $0.addProfile(name: name, color: color) }
        return profile
    }

    /// Edit Profile's fields. A blank name (after trimming) keeps the old one.
    func updateProfile(_ profileID: UUID, name: String, color: Swatch) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        changeState { state in
            state.updateProfile(profileID) { profile in
                if !name.isEmpty { profile.name = name }
                profile.color = color
            }
        }
    }

    /// Deletes the profile: its Spaces switch to the default profile, their tabs reloading there, and
    /// its website data and history are erased. Not the default profile.
    func deleteProfile(_ profileID: UUID) {
        // Its tabs' web views go with the change (`releaseSessionsOnOtherProfiles`), so nothing holds
        // its data store by the time it's erased.
        changeState { $0.deleteProfile(profileID) }
        eraseDeletedProfiles()
    }

    // MARK: Website data

    /// How many sites keep data (cookies, storage, caches) in the profile; nil for a profile that's
    /// gone. WebKit doesn't say how much they hold.
    func websiteDataSiteCount(of profileID: UUID) async -> Int? {
        guard state.profile(profileID) != nil else { return nil }
        return await TabSession.dataStore(for: profileID)
            .dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).count
    }

    /// Erases the profile's cookies and website data, signing it out of every site. Its tabs' web views
    /// go first, so no page writes anything back meanwhile, and are rebuilt after (as for a change of
    /// profile), so none goes on as if signed in. History stays.
    func clearWebsiteData(of profileID: UUID) async {
        guard state.profile(profileID) != nil else { return }
        releaseSessions { session, _ in session.profileID == profileID }
        await TabSession.dataStore(for: profileID)
            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        changeState { _ in }
    }

    // MARK: Erasing deleted profiles

    /// Erases the history and website data store of every profile the state lists as deleted
    /// (`profilesToErase`), then takes it off the list once both are confirmed gone. Only once the
    /// state that deleted it is on disk (`savedState()`), and never from the empty state a load failure
    /// leaves (`canSave`), so a file that didn't load can't cause anything to be erased, and a deletion
    /// can't come back at the next launch with its data gone. While a store is still in use, every
    /// profile left is tried again after `profileErasureWaits`, or as soon as the pass running ends
    /// when asked meanwhile (the last web view on it going, `TabSession.onRelease`); after that, and
    /// when it's the history that couldn't go, it's left on the list for the next return to the app
    /// or the next launch.
    func eraseDeletedProfiles() {
        guard canSave, !state.profilesToErase.isEmpty else { return }
        guard profileErasure == nil else {
            erasesProfilesAgain = true
            return
        }
        profileErasure = Task {
            var waits = Self.profileErasureWaits.makeIterator()
            while true {
                erasesProfilesAgain = false
                let storeInUse = await eraseDeletedProfilesOnce()
                if erasesProfilesAgain {
                    // Something changed meanwhile (a profile deleted, a web view gone): again now.
                    waits = Self.profileErasureWaits.makeIterator()
                    continue
                }
                guard storeInUse, canSave, let wait = waits.next() else { break }
                try? await Task.sleep(for: wait)
            }
            profileErasure = nil
        }
    }

    /// How long a pass that left a store in use waits before the next, about two minutes in all.
    /// WebKit lets go of a store some time after the last web view on it goes: once its web content
    /// process has exited, then the network process's session on it. That took from a few seconds to
    /// over forty on CI.
    private static let profileErasureWaits: [Duration] = [1, 2, 4, 8].map(Duration.seconds)
        + Array(repeating: .seconds(15), count: 8)

    /// One try at each profile on the list. Returns whether one is left because its store was still in
    /// use. History that couldn't go (no history database, a failed write) isn't tried again until the
    /// next return to the app: waiting doesn't help it.
    private func eraseDeletedProfilesOnce() async -> Bool {
        var storeInUse = false
        var erased = false
        var tried = Set<UUID>()
        // Read each time round: a profile deleted meanwhile is erased in this pass too.
        while canSave, let profileID = state.profilesToErase.first(where: { !tried.contains($0) }) {
            tried.insert(profileID)
            // `normalize` keeps these off the list; this keeps a store in use from ever being erased.
            guard profileID != Profile.defaultID, state.profile(profileID) == nil,
                  let saved = await savedState(), saved.profile(profileID) == nil,
                  saved.profilesToErase.contains(profileID) else { continue }
            // Both tried each time, whichever failed before.
            let storeGone = await removeDataStore(of: profileID)
            let historyGone = await afterBrowsingHistoryWrites { await $0.removeProfile(profileID) } == true
            if storeGone, historyGone {
                changeState { $0.profileErased(profileID) }
                erased = true
            }
            if !storeGone { storeInUse = true }
        }
        if erased { forgetFavicons() }
        return storeInUse
    }

    /// Removes the profile's website data store. Returns whether it's gone (or never existed: a
    /// profile never used has none); false while a web view, or WebKit, still holds it.
    private func removeDataStore(of profileID: UUID) async -> Bool {
        // Looked up each time: one may have been made since the last look.
        guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(profileID) else { return true }
        guard canSave, !hasWebViews(usingProfile: profileID) else { return false }
        // Emptied through WebKit first. Its network process can still hold the profile's cookies after
        // the last web view on it goes, and write them back into the store's folder once that's been
        // removed: CormorantTests found a site's data back in a store erased moments before. Emptying
        // the store clears what the network process holds too, so anything it writes later is empty.
        await Self.emptyDataStore(of: profileID)
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: profileID)
            return true
        } catch {
            Logger.app.notice("Couldn't erase a deleted profile's website data yet: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Removes everything in the profile's store. A function of its own so the store object it makes is
    /// gone by the time `remove(forIdentifier:)` runs, which fails while one is alive.
    private static func emptyDataStore(of profileID: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    #if DEBUG
    /// UI tests (`-uiTesting`) make a profile, and a store, in most runs, and the state they ran in is
    /// thrown away: remove every store the state just loaded doesn't use, so the simulator doesn't
    /// collect them. Not a deleted profile's: erasing that is `eraseDeletedProfiles`'s job, which a
    /// relaunch test checks.
    func removeUITestingDataStores() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return }
        let profiles = Set(state.profiles.map(\.id)).union(state.profilesToErase)
        Task {
            for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !profiles.contains(id) {
                try? await WKWebsiteDataStore.remove(forIdentifier: id)
            }
        }
    }
    #endif
}
