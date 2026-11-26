import CormorantCore
import Foundation
import Testing
@testable import CormorantSync

private typealias Shared = BrowserState.Shared

private func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

/// Home, the default profile and nothing else: what a new install shares.
private func fresh() -> Shared { BrowserState().shared }

/// A device and the cloud it syncs with, without encryption or CloudKit: saves are refused when the
/// cloud's copy isn't the one the device last knew, as CloudKit refuses them.
private struct Device {
    var shared = fresh()
    var ledger = SyncLedger()
    /// How far into the cloud's change log this device has fetched.
    var fetched = 0

    mutating func change(_ edit: (inout BrowserState) -> Void) {
        var state = BrowserState()
        state.setShared(shared)
        edit(&state)
        ledger.noteLocalChange(from: shared, to: state.shared)
        shared = state.shared
    }

    mutating func sync(with cloud: inout Cloud) {
        for _ in 0..<10 {
            let news = cloud.changes(since: fetched)
            fetched = cloud.log.count
            shared = ledger.receive(saves: news.saves, deletes: news.deletes, local: shared)
            let pending = ledger.pendingChanges(local: shared)
            if pending.isEmpty { return }
            for (id, record) in pending.saves {
                if cloud.records[id] == ledger.baseline[id] {
                    cloud.save(id, record)
                    ledger.sent(id, record)
                } else if let theirs = cloud.records[id] {
                    shared = ledger.receive(saves: [id: theirs], local: shared)
                } else {
                    shared = ledger.receive(saves: [:], deletes: [id], local: shared)
                }
            }
            for id in pending.deletes {
                cloud.delete(id)
                ledger.deleted(id)
            }
            // Its own writes are in the log too; fetching them again changes nothing.
        }
        Issue.record("sync didn't settle")
    }
}

private struct Cloud {
    var records: SyncSnapshot = [:]
    var log: [(id: SyncRecordID, record: SyncRecord?)] = []

    mutating func save(_ id: SyncRecordID, _ record: SyncRecord) {
        records[id] = record
        log.append((id, record))
    }

    mutating func delete(_ id: SyncRecordID) {
        records[id] = nil
        log.append((id, nil))
    }

    func changes(since index: Int) -> (saves: SyncSnapshot, deletes: Set<SyncRecordID>) {
        var saves: SyncSnapshot = [:], deletes = Set<SyncRecordID>()
        for entry in log[index...] {
            if let record = entry.record {
                saves[entry.id] = record
                deletes.remove(entry.id)
            } else {
                saves[entry.id] = nil
                deletes.insert(entry.id)
            }
        }
        return (saves, deletes)
    }
}

@Suite struct RecordTests {
    @Test func stateSurvivesBecomingRecords() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo)
        _ = state.openTab(url: url("a"), title: "A")
        let pinned = state.openTab(url: url("b"), title: "B", inSpace: work.id)
        state.pin(tabID: pinned.id)
        let closing = state.openTab(url: url("c"), title: "C")
        state.archive(tabID: closing.id)

        let shared = SyncSnapshot(state.shared).shared
        #expect(shared.spaces == state.shared.spaces)
        #expect(shared.profiles == state.shared.profiles)
        #expect(shared.tabs == state.shared.tabs)
        #expect(shared.archived == state.shared.archived)
    }

    @Test func incognitoAndBlankTabsAreNeverRecords() {
        var state = BrowserState()
        let kept = state.openTab(url: url("kept"))
        let blank = state.openTab(url: nil)
        let secret = state.openIncognitoTab(url: url("secret"), title: "Secret")

        let records = SyncSnapshot(state.shared)
        #expect(records[.tab(secret.id)] == nil)
        #expect(records[.tab(blank.id)] == nil)
        #expect(records[.tab(kept.id)] != nil)
        #expect(records[.space(Space.incognitoID)] == nil)
        #expect(records[.tabOrder]?.ids == [kept.id])
        // Even handed one directly.
        let forced = SyncSnapshot(Shared(tabs: [secret, blank]))
        #expect(forced.keys.allSatisfy { $0.kind == .order })
        let encoded = String(decoding: try! JSONEncoder().encode(records.mapKeys(\.name)), as: UTF8.self)
        #expect(!encoded.contains("secret"))
    }

    @Test func recordIDsMatchTheRecords() {
        var state = BrowserState()
        state.addSpace(name: "Work")
        _ = state.openTab(url: url("a"))
        _ = state.openTab(url: nil)
        #expect(SyncSnapshot.ids(of: state.shared) == Set(SyncSnapshot(state.shared).keys))
    }

    @Test func aNewerBuildsFieldsAndValuesAreKept() throws {
        var state = BrowserState()
        let tab = state.openTab(url: url("a"), title: "A")
        var cloud = SyncSnapshot(state.shared)
        cloud[.tab(tab.id)]!.fields["folderID"] = .string("F1")
        cloud[.tab(tab.id)]!.fields["kind"] = .string("folder")
        var ledger = SyncLedger()
        let merged = ledger.receive(saves: cloud, local: fresh())

        // Read as this build can, and nothing to send back.
        #expect(merged.tabs.first?.kind == .today)
        #expect(ledger.pendingChanges(local: merged).isEmpty)

        // A change here sends the record with the newer build's parts intact.
        var edited = merged
        edited.tabs[0].title = "Renamed"
        let sent = try #require(ledger.pendingChanges(local: edited).saves[.tab(tab.id)])
        #expect(sent.fields["title"] == .string("Renamed"))
        #expect(sent.fields["folderID"] == .string("F1"))
        #expect(sent.fields["kind"] == .string("folder"))
    }

    @Test func aRecordThatDoesNotReadIsSkipped() {
        var records = SyncSnapshot(fresh())
        records[.tab(UUID())] = SyncRecord(fields: ["title": .number(3)])
        #expect(records.shared.tabs.isEmpty)
        #expect(records.shared.spaces.map(\.id) == [Space.defaultID])
    }

    @Test func ledgerSurvivesSaving() throws {
        var device = Device()
        var cloud = Cloud()
        device.change { _ = $0.openTab(url: url("a")) }
        device.sync(with: &cloud)
        device.change { $0.archive(tabID: $0.tabs[0].id) }
        #expect(!device.ledger.pendingDeletes.isEmpty)
        let data = try JSONEncoder().encode(device.ledger)
        #expect(try JSONDecoder().decode(SyncLedger.self, from: data) == device.ledger)
    }
}

private extension Dictionary {
    func mapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey) -> [NewKey: Value] {
        Dictionary<NewKey, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

@Suite struct MergeTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test func listKeepsBothDevicesAdditions() {
        #expect(SyncMerge.list(base: [a, b], local: [a, c, b], remote: [a, b, d]) == [a, c, b, d])
    }

    @Test func listDropsWhatEitherRemoved() {
        #expect(SyncMerge.list(base: [a, b, c], local: [a, c], remote: [a, b]) == [a])
    }

    @Test func listTakesThisDevicesOrderWhenOnlyItReordered() {
        #expect(SyncMerge.list(base: [a, b, c], local: [c, a, b], remote: [a, b, c, d]) == [c, d, a, b])
    }

    @Test func listTakesTheOtherDevicesOrderWhenBothReordered() {
        #expect(SyncMerge.list(base: [a, b, c], local: [c, a, b, e], remote: [b, a, c]) == [b, e, a, c])
    }

    @Test func listsWithNoSharedPastAreJoined() {
        #expect(SyncMerge.list(base: [], local: [a, b], remote: [a, c]) == [a, b, c])
    }

    @Test func fieldsChangedOnEachDeviceBothSurvive() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var work: UUID!
        phone.change { work = $0.addSpace(name: "Work").id }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)

        phone.change { state in _ = state.updateSpace(work) { $0.name = "Job" } }
        mac.change { state in _ = state.updateSpace(work) { $0.color = .pink } }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)

        let space = phone.shared.spaces.first { $0.id == work }
        #expect(space?.name == "Job")
        #expect(space?.color == .pink)
        #expect(phone.shared == mac.shared)
    }

    @Test func theSameFieldChangedOnBothTakesTheLaterSave() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var work: UUID!
        phone.change { work = $0.addSpace(name: "Work").id }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)

        phone.change { state in _ = state.updateSpace(work) { $0.name = "Phone" } }
        mac.change { state in _ = state.updateSpace(work) { $0.name = "Mac" } }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)

        #expect(phone.shared.spaces.first { $0.id == work }?.name == "Mac")
        #expect(phone.shared == mac.shared)
    }
}

@Suite struct TwoDeviceTests {
    @Test func firstSyncJoinsBothDevices() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        phone.change { state in
            _ = state.updateSpace(Space.defaultID) { $0.name = "Phone Home" }
            state.addSpace(name: "Travel")
            _ = state.openTab(url: url("phone"))
        }
        mac.change { state in
            _ = state.updateSpace(Space.defaultID) { $0.name = "Mac Home" }
            state.addSpace(name: "Work")
            _ = state.openTab(url: url("mac"))
        }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)

        #expect(phone.shared == mac.shared)
        // The first device there named Home; nothing of either's is lost.
        #expect(mac.shared.spaces.map(\.name) == ["Phone Home", "Work", "Travel"])
        #expect(Set(mac.shared.tabs.compactMap(\.url)) == [url("phone"), url("mac")])
    }

    @Test func closingATabClosesItOnTheOtherDeviceAndArchivesIt() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var tab: UUID!
        phone.change { tab = $0.openTab(url: url("a"), title: "A").id }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        #expect(mac.shared.tabs.map(\.id) == [tab])

        mac.change { $0.archive(tabID: tab) }
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)

        #expect(phone.shared.tabs.isEmpty)
        #expect(phone.shared.archived.map(\.id) == [tab])
        #expect(phone.shared == mac.shared)
    }

    @Test func aTabClosedOnOneDeviceStaysClosedThoughItMovedOnTheOther() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var tab: UUID!
        phone.change { tab = $0.openTab(url: url("a")).id }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)

        mac.change { $0.archive(tabID: tab) }
        phone.change { $0.update(tabID: tab, url: url("b"), title: "B") }
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)

        #expect(phone.shared.tabs.isEmpty)
        #expect(mac.shared.tabs.isEmpty)
        #expect(phone.shared == mac.shared)

        // The other way round: the page changes reach the cloud first, then the close.
        phone.change { tab = $0.openTab(url: url("c")).id }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        mac.change { $0.archive(tabID: tab) }
        phone.change { $0.update(tabID: tab, url: url("d"), title: "D") }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)
        #expect(phone.shared.tabs.isEmpty)
        #expect(phone.shared == mac.shared)
    }

    @Test func aStateThatLostEverythingDeletesNothing() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        phone.change { state in
            state.addSpace(name: "Work")
            _ = state.openTab(url: url("a"))
        }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        let before = mac.shared

        // The phone's state file is gone (or Start Fresh): it loads empty, with nothing seen removed.
        phone.shared = fresh()
        #expect(phone.ledger.pendingChanges(local: phone.shared).deletes.isEmpty)
        phone.shared = phone.ledger.restoringMissing(in: phone.shared)
        #expect(phone.shared == before)
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        #expect(mac.shared == before)
        #expect(cloud.records.count == SyncSnapshot(before).count)
    }

    @Test func aNewDeviceWithNoLedgerDeletesNothing() {
        var phone = Device(), cloud = Cloud()
        phone.change { state in
            state.addSpace(name: "Work")
            _ = state.openTab(url: url("a"))
        }
        phone.sync(with: &cloud)
        var mac = Device()
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)
        #expect(mac.shared == phone.shared)
        #expect(mac.shared.spaces.count == 2)
        #expect(mac.shared.tabs.count == 1)
    }

    @Test func aTabThatArrivesBeforeItsSpaceWaitsForIt() throws {
        var phone = Device(), cloud = Cloud()
        var work: UUID!, profile: UUID!
        phone.change { state in
            profile = state.addProfile(name: "Work").id
            work = state.addSpace(name: "Work", profileID: profile).id
            _ = state.openTab(url: url("first"))
            _ = state.openTab(url: url("a"), inSpace: work)
        }
        phone.sync(with: &cloud)
        let tab = try #require(phone.shared.tabs.first { $0.spaceID == work })

        // The Mac gets the tab and the lists first, then the Space, then its profile.
        var mac = Device()
        let early: Set<SyncRecordID> = [.tab(tab.id), .tabOrder, .spaceOrder]
        mac.shared = mac.ledger.receive(saves: cloud.records.filter { early.contains($0.key) }, local: mac.shared)
        #expect(mac.shared.tabs.isEmpty)
        #expect(mac.ledger.pendingChanges(local: mac.shared).saves.keys.allSatisfy { $0 == .space(Space.defaultID) || $0 == .profile(Profile.defaultID) })
        mac.shared = mac.ledger.receive(saves: cloud.records.filter { $0.key == .space(work) }, local: mac.shared)
        #expect(mac.shared.tabs.isEmpty)
        #expect(!mac.shared.spaces.contains { $0.id == work })
        mac.shared = mac.ledger.receive(saves: cloud.records, local: mac.shared)

        #expect(mac.shared.tabs.first { $0.id == tab.id }?.spaceID == work)
        #expect(mac.shared.spaces.first { $0.id == work }?.profileID == profile)
        #expect(mac.shared.tabs.map(\.id) == phone.shared.tabs.map(\.id))
        #expect(mac.ledger.pendingChanges(local: mac.shared).isEmpty)
    }

    @Test func aTabMovedToASpaceThatHasNotArrivedStaysWhereItIs() throws {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var tab: UUID!
        phone.change { tab = $0.openTab(url: url("a")).id }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)

        var work: UUID!
        phone.change { state in
            work = state.addSpace(name: "Work").id
            _ = state.moveTab(tab, toSpace: work)
        }
        phone.sync(with: &cloud)

        // The Mac gets the moved tab before the Space it moved to.
        mac.shared = mac.ledger.receive(saves: cloud.records.filter { $0.key == .tab(tab) }, local: mac.shared)
        #expect(mac.shared.tabs.first?.spaceID == Space.defaultID)
        #expect(mac.ledger.pendingChanges(local: mac.shared).isEmpty)
        mac.shared = mac.ledger.receive(saves: cloud.records.filter { $0.key != .tab(tab) }, local: mac.shared)
        #expect(mac.shared.tabs.first?.spaceID == work)
        #expect(mac.ledger.pendingChanges(local: mac.shared).isEmpty)
        #expect(mac.shared == phone.shared)
    }

    @Test func aRecordThatDoesNotReadAsItsKindIsLeftAloneWithWhatPointsAtIt() throws {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var profile: UUID!, work: UUID!
        phone.change { state in
            profile = state.addProfile(name: "Work").id
            work = state.addSpace(name: "Work", profileID: profile).id
        }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        let before = mac.shared

        // A newer build rewrites the profile in a shape this one can't read.
        var record = cloud.records[.profile(profile)]!
        record.fields["name"] = .object(["text": .string("Work")])
        cloud.save(.profile(profile), record)
        mac.sync(with: &cloud)
        // Still there (its website data isn't erased), its Space still on it, and not saved over.
        #expect(mac.shared == before)
        #expect(cloud.records[.profile(profile)] == record)
        mac.change { state in state.updateProfile(profile) { $0.name = "Renamed" } }
        mac.sync(with: &cloud)
        #expect(cloud.records[.profile(profile)] == record)

        // A device that never had it: the Space waits for a profile it can read.
        var tablet = Device()
        tablet.sync(with: &cloud)
        #expect(!tablet.shared.spaces.contains { $0.id == work })
        #expect(cloud.records[.space(work)]?.fields["profileID"] == .string(profile.uuidString))
    }

    @Test func aRecordThisBuildDoesNotKnowStaysInTheCloud() {
        // A folder, from the build that has them: its tab keeps pointing at it.
        var phone = Device(), cloud = Cloud()
        phone.change { _ = $0.openTab(url: url("a")) }
        phone.sync(with: &cloud)
        let tab = phone.shared.tabs[0].id, folder = UUID()
        cloud.save(.folder(folder), SyncRecord(fields: ["id": .string(folder.uuidString), "spaceID": .string(Space.defaultID.uuidString)]))
        var record = cloud.records[.tab(tab)]!
        record.fields["folderID"] = .string(folder.uuidString)
        cloud.save(.tab(tab), record)

        phone.sync(with: &cloud)
        phone.change { $0.update(tabID: tab, url: url("b"), title: "B") }
        phone.sync(with: &cloud)
        #expect(cloud.records[.folder(folder)] != nil)
        #expect(cloud.records[.tab(tab)]?.fields["folderID"] == .string(folder.uuidString))
        #expect(cloud.records[.tab(tab)]?.fields["title"] == .string("B"))
    }

    @Test func tabsOpenedOnBothDevicesKeepAnOrderBothAgreeOn() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        phone.change { _ = $0.openTab(url: url("first")) }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        phone.change { _ = $0.openTab(url: url("phone")) }
        mac.change { _ = $0.openTab(url: url("mac")) }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        phone.sync(with: &cloud)
        #expect(phone.shared.tabs.count == 3)
        #expect(phone.shared.tabs.map(\.id) == mac.shared.tabs.map(\.id))
        #expect(phone.shared == mac.shared)
    }

    @Test func aDeletedProfileGoesFromBoth() {
        var phone = Device(), mac = Device(), cloud = Cloud()
        var profile: UUID!
        phone.change { state in
            profile = state.addProfile(name: "Work").id
            state.addSpace(name: "Work", profileID: profile)
        }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        #expect(mac.shared.profiles.contains { $0.id == profile })

        phone.change { _ = $0.deleteProfile(profile) }
        phone.sync(with: &cloud)
        mac.sync(with: &cloud)
        #expect(!mac.shared.profiles.contains { $0.id == profile })
        var state = BrowserState()
        state.setShared(mac.shared)
        #expect(state.spaces.allSatisfy { $0.profileID == Profile.defaultID })
    }
}

@Suite struct CipherTests {
    private let record = SyncRecord(fields: ["title": .string("Bank"), "url": .string("https://bank.example/account")])
    private let id = SyncRecordID.tab(UUID())

    @Test func recordsRoundTrip() throws {
        let key = SyncKey()
        let sealed = try SyncCipher.seal(record, id: id, with: key)
        let opened = try SyncCipher.open(sealed, with: [SyncKey(), key])
        #expect(opened.id == id)
        #expect(opened.record == record)
    }

    @Test func nothingReadableIsStored() throws {
        let sealed = try SyncCipher.seal(record, id: id, with: SyncKey())
        let stored = sealed.payload + Data(sealed.name.utf8) + Data(sealed.keyID.utf8)
        for secret in ["bank", "Bank", "tab", id.name] {
            #expect(stored.range(of: Data(secret.utf8)) == nil)
        }
        // Nonce (12) + padded plaintext + tag (16).
        #expect((sealed.payload.count - 28) % SyncCipher.padding == 0)
    }

    @Test func sealingTwiceGivesDifferentBytes() throws {
        let key = SyncKey()
        #expect(try SyncCipher.seal(record, id: id, with: key).payload != SyncCipher.seal(record, id: id, with: key).payload)
    }

    @Test func aRecordNeedsItsKey() throws {
        let key = SyncKey()
        let sealed = try SyncCipher.seal(record, id: id, with: key)
        #expect(throws: SyncCipherError.missingKey(id: key.id)) { try SyncCipher.open(sealed, with: [SyncKey()]) }
    }

    @Test func aRecordCannotBePassedOffAsAnother() throws {
        let key = SyncKey()
        var sealed = try SyncCipher.seal(record, id: id, with: key)
        sealed.name = SyncCipher.name(for: .tab(UUID()))
        #expect(throws: SyncCipherError.unreadable) { try SyncCipher.open(sealed, with: [key]) }
    }

    @Test func alteredBytesAreRefused() throws {
        let key = SyncKey()
        var sealed = try SyncCipher.seal(record, id: id, with: key)
        sealed.payload[20] ^= 1
        #expect(throws: SyncCipherError.unreadable) { try SyncCipher.open(sealed, with: [key]) }
    }

    @Test func aNewerFormatIsLeftAlone() throws {
        let key = SyncKey()
        var sealed = try SyncCipher.seal(record, id: id, with: key)
        sealed.version = SyncCipher.version + 1
        #expect(throws: SyncCipherError.newerVersion(SyncCipher.version + 1)) { try SyncCipher.open(sealed, with: [key]) }
    }

    @Test func keysAreNamedWithoutBeingGivenAway() {
        let key = SyncKey()
        #expect(SyncKey(data: key.data) == key)
        #expect(SyncKey(data: Data(repeating: 1, count: 16)) == nil)
        #expect(SyncKey().id != key.id)
        #expect(!key.data.map { String(format: "%02x", $0) }.joined().contains(key.id))
    }
}

@Suite struct SyncStatusTests {
    @Test func offSaysNothing() {
        #expect(SyncStatus(.disabled) == nil)
    }

    @Test func onlyAFailureOffersTryAgain() {
        #expect(SyncStatus(.idle) == SyncStatus(text: "Up to date"))
        #expect(SyncStatus(.syncing)?.needsAttention == false)
        #expect(SyncStatus(.waitingForKey)?.needsAttention == true)
        #expect(SyncStatus(.waitingForKey)?.canRetry == false)
        #expect(SyncStatus(.noAccount)?.text == "Sign in to iCloud to sync.")
        #expect(SyncStatus(.failed("No connection to iCloud.")) ==
            SyncStatus(text: "No connection to iCloud.", needsAttention: true, canRetry: true))
    }

    @Test func theExplanationNamesThisDeviceFirst() {
        #expect(SyncStatus.explanation(device: "iPhone").contains("on your iPhone and Mac"))
        #expect(SyncStatus.explanation(device: "Mac").contains("on your Mac and iPhone"))
        #expect(SyncStatus.explanation(device: "Mac").hasSuffix("never leave this Mac."))
    }
}
