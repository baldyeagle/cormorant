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
    /// can't come back at the next launch with its data gone. A store still in use (a web view not yet
    /// gone) is tried again a few times, then left on the list for when the last web view on it goes
    /// (`TabSession.onRelease`), the next return to the app, or the next launch.
    func eraseDeletedProfiles() {
        guard canSave, !state.profilesToErase.isEmpty else { return }
        guard profileErasure == nil else {
            erasesProfilesAgain = true
            return
        }
        profileErasure = Task {
            defer {
                profileErasure = nil
                if erasesProfilesAgain {
                    erasesProfilesAgain = false
                    eraseDeletedProfiles()
                }
            }
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
                if storeGone, historyGone { changeState { $0.profileErased(profileID) } }
            }
            forgetFavicons()
        }
    }

    /// Removes the profile's website data store, trying again after 1, 2 and 4 seconds while it's in
    /// use. Returns whether it's gone (or never existed: a profile never used has none).
    private func removeDataStore(of profileID: UUID) async -> Bool {
        for delay in [0, 1, 2, 4] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            // Looked up each time: one may have been made since the last look.
            guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(profileID) else { return true }
            guard canSave, !hasWebViews(usingProfile: profileID) else { continue }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: profileID)
                return true
            } catch {
                Logger.app.notice("Couldn't erase a deleted profile's website data yet: \(error.localizedDescription, privacy: .public)")
            }
        }
        return false
    }

    #if DEBUG
    /// UI tests (`-uiTesting`) make a profile, and a store, in most runs, and the state they ran in is
    /// thrown away: remove every store the state just loaded doesn't use, so the simulator doesn't
    /// collect them.
    func removeUITestingDataStores() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return }
        let profiles = Set(state.profiles.map(\.id))
        Task {
            for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !profiles.contains(id) {
                try? await WKWebsiteDataStore.remove(forIdentifier: id)
            }
        }
    }
    #endif
}
