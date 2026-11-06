import Foundation
import Testing
@testable import CormorantCore

@Suite struct ProfilesTests {
    // MARK: Erasing deleted profiles

    @Test func deletingAProfileQueuesItsDataForErasing() throws {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        #expect(state.profilesToErase.isEmpty)

        #expect(state.deleteProfile(vialumi.id) == [work.id])
        #expect(state.profilesToErase == [vialumi.id])
        #expect(state.profile(forSpace: work.id).isDefault)

        state.profileErased(vialumi.id)
        #expect(state.profilesToErase.isEmpty)
    }

    @Test func theDefaultAndUnknownProfilesAreNeverQueued() {
        var state = BrowserState()
        #expect(state.deleteProfile(Profile.defaultID) == nil)
        #expect(state.deleteProfile(UUID()) == nil)
        #expect(state.profilesToErase.isEmpty)
    }

    @Test func profilesToEraseSurviveSavingAndLoading() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONBrowserStateStore(fileURL: dir.appending(path: "state.json"))
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        state.deleteProfile(vialumi.id)
        try await store.save(state)

        let loaded = try await store.load()
        #expect(loaded.profilesToErase == [vialumi.id])
        #expect(loaded == state)
    }

    /// A file is only ever trusted to name what to erase: never a profile it still lists, the default
    /// profile, or the same one twice.
    @Test func decodingDropsErasuresOfProfilesThatExist() throws {
        let kept = UUID(), gone = UUID()
        let json = """
            {"schemaVersion":4,
             "profiles":[{"id":"\(Profile.defaultID)","name":"Default"},{"id":"\(kept)","name":"Vialumi"}],
             "profilesToErase":["\(kept)","\(Profile.defaultID)","\(gone)","\(gone)"]}
            """
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.profilesToErase == [gone])
        #expect(state.profile(kept) != nil)
    }

    @Test func filesWithoutErasuresDecodeWithNone() throws {
        let json = "{\"schemaVersion\":3,\"spaces\":[{\"id\":\"\(Space.defaultID)\",\"name\":\"Home\"}]}"
        let state = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(state.profilesToErase.isEmpty)
        // And nothing is written for them.
        let written = String(decoding: try CoreJSON.encoder().encode(state), as: UTF8.self)
        #expect(!written.contains("profilesToErase"))
    }

    /// Start Fresh and a missing file both begin from `.empty`, which names nothing to erase.
    @Test func anEmptyStateErasesNothing() {
        #expect(BrowserState.empty.profilesToErase.isEmpty)
    }

    // MARK: Lookups

    @Test func activeProfileFollowsTheActiveSpace() {
        var state = BrowserState()
        let vialumi = state.addProfile(name: "Vialumi")
        let work = state.addSpace(name: "Work", profileID: vialumi.id)
        #expect(state.activeProfile.isDefault)
        state.switchToSpace(work.id)
        #expect(state.activeProfile.id == vialumi.id)
        state.updateSpace(work.id) { $0.profileID = Profile.defaultID }
        #expect(state.activeProfile.isDefault)
    }

    @Test func suggestedColorSkipsTakenOnes() {
        var state = BrowserState()
        // The default profile is blue.
        #expect(state.suggestedNewProfileColor == .teal)
        state.addProfile(name: "A", color: .teal)
        #expect(state.suggestedNewProfileColor == .indigo)
        for color in Swatch.allCases { state.addProfile(name: color.rawValue, color: color) }
        #expect(state.suggestedNewProfileColor == Swatch.allCases[0])
    }

    @Test func profilesListTheDefaultFirstThenOldestFirst() {
        var state = BrowserState()
        let later = state.addProfile(name: "Later", now: t0 + hour)
        let earlier = state.addProfile(name: "Earlier", now: t0)
        #expect(state.profilesInOrder.map(\.id) == [Profile.defaultID, earlier.id, later.id])
    }
}
