import CormorantCore
@testable import CormorantSync
import CormorantTestSupport
import Foundation
import Testing

/// A device: a state and the engine that syncs it, as the app wires them.
@MainActor
private final class Device {
    var state = BrowserState()
    /// False stands for a state that didn't load (unreadable, not started fresh).
    var canSync = true
    let keys: FakeSyncKeyStore
    private(set) var engine: SyncEngine!
    let fileURL: URL?
    /// How many times the engine has read the state.
    private(set) var reads = 0
    private var editsAtRead: [Int: (inout BrowserState) -> Void] = [:]
    /// Whether every edit asked for with `change(atRead:)` has been made.
    var madeEveryEdit: Bool { editsAtRead.isEmpty }

    /// Makes `edit` just before the engine reads the state for the `count`th time from now: a change
    /// landing at that point of a round.
    func change(atRead count: Int, _ edit: @escaping (inout BrowserState) -> Void) {
        editsAtRead[reads + count] = edit
    }

    /// The state's file takes its time to be written: the session's file waits for it.
    var holdsSaves = false
    private var heldSaves: [CheckedContinuation<Void, Never>] = []

    func releaseSaves() {
        holdsSaves = false
        for held in heldSaves { held.resume() }
        heldSaves = []
    }

    /// A state something keeps changing: an edit before every read.
    var changesAtEveryRead: ((inout BrowserState) -> Void)?

    init(cloud: FakeSyncCloud, keys: FakeSyncKeyStore = FakeSyncKeyStore(), fileURL: URL? = nil) {
        self.keys = keys
        self.fileURL = fileURL
        engine = makeEngine(cloud: cloud)
    }

    func makeEngine(cloud: FakeSyncCloud) -> SyncEngine {
        SyncEngine(cloud: cloud, keyStore: keys, fileURL: fileURL, debounce: .seconds(3600),
                   stateSaved: { [unowned self] in
                       if holdsSaves { await withCheckedContinuation { heldSaves.append($0) } }
                   },
                   local: { [unowned self] in
                       reads += 1
                       if let edit = changesAtEveryRead { change(edit) }
                       if let edit = editsAtRead.removeValue(forKey: reads) { change(edit) }
                       return canSync ? state.shared : nil
                   },
                   apply: { [unowned self] in state.setShared($0) })
    }

    /// A relaunch: a new engine reading the session the last one saved.
    func relaunch(cloud: FakeSyncCloud) async {
        await engine.finish()
        engine = makeEngine(cloud: cloud)
        engine.start()
    }

    func change(_ edit: (inout BrowserState) -> Void) {
        let old = state.shared
        edit(&state)
        engine.localDidChange(from: old, to: state.shared)
    }

    func sync() async { await engine.sync() }
}

private func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)/sync-state.json")
}

@MainActor
@Suite struct SyncEngineTests {
    let cloud = FakeSyncCloud()
    /// One keychain for both devices: iCloud Keychain, caught up.
    let keychain = FakeSyncKeyStore()

    private func pair() -> (Device, Device) {
        let phone = Device(cloud: cloud, keys: keychain), mac = Device(cloud: cloud, keys: keychain)
        phone.engine.start()
        mac.engine.start()
        return (phone, mac)
    }

    @Test func changesCrossBothWays() async {
        let (phone, mac) = pair()
        phone.change { state in
            state.addSpace(name: "Work")
            _ = state.openTab(url: url("a"), title: "A")
        }
        await phone.sync()
        await mac.sync()
        #expect(mac.state.shared == phone.state.shared)
        #expect(mac.state.tabs.map(\.title) == ["A"])

        mac.change { $0.archive(tabID: $0.tabs[0].id) }
        await mac.sync()
        await phone.sync()
        #expect(phone.state.tabs.isEmpty)
        #expect(phone.state.archived.map(\.title) == ["A"])
        #expect(phone.engine.state == .idle)
        #expect(phone.engine.lastSyncedAt != nil)
    }

    @Test func theCloudOnlyHoldsCiphertext() async throws {
        let (phone, _) = pair()
        phone.change { _ = $0.openTab(url: url("private-page"), title: "Very Private") }
        await phone.sync()
        let stored = await cloud.stored
        #expect(stored.count >= 4)
        for record in stored.values {
            let bytes = record.payload + Data(record.name.utf8)
            for secret in ["private-page", "Very Private", "example.com", "tab."] {
                #expect(bytes.range(of: Data(secret.utf8)) == nil)
            }
        }
    }

    @Test func incognitoNeverReachesTheCloud() async throws {
        let (phone, mac) = pair()
        phone.change { state in
            _ = state.openTab(url: url("a"))
            state.openIncognitoTab(url: url("secret"), title: "Secret")
        }
        await phone.sync()
        await mac.sync()
        #expect(mac.state.tabs.compactMap(\.url) == [url("a")])
        // Tab, Home, default profile, two lists.
        #expect(await cloud.stored.count == 5)
        #expect(phone.state.isIncognitoOpen)

        // A change from the Mac leaves the phone's Incognito tab where it is.
        mac.change { _ = $0.openTab(url: url("b")) }
        await mac.sync()
        await phone.sync()
        #expect(phone.state.tabs.contains { $0.isIncognito && $0.url == url("secret") })
        #expect(phone.state.activeSpaceID == Space.incognitoID)
        #expect(phone.state.shared.tabs.count == 2)
    }

    @Test func aStateThatCannotBeSyncedIsLeftAlone() async {
        let (phone, mac) = pair()
        phone.change { _ = $0.openTab(url: url("a")) }
        await phone.sync()

        // The Mac's state file was unreadable: nothing is fetched into it or sent from it.
        let broken = Device(cloud: cloud, keys: keychain)
        broken.canSync = false
        broken.engine.start()
        await broken.sync()
        #expect(!broken.engine.isOn)
        #expect(broken.state.tabs.isEmpty)

        // Start Fresh: it joins as a new device and takes nothing away.
        broken.canSync = true
        broken.engine.start()
        broken.engine.stateWasReset()
        await broken.sync()
        await mac.sync()
        #expect(broken.state.shared == phone.state.shared)
        #expect(mac.state.tabs.count == 1)
    }

    @Test func aRemovalSurvivesARelaunchBeforeItWasSent() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file), mac = Device(cloud: cloud, keys: keychain)
        phone.engine.start()
        mac.engine.start()
        phone.change { _ = $0.openTab(url: url("a")) }
        await phone.sync()
        await mac.sync()

        await cloud.fail(with: .failed("offline"))
        phone.change { $0.archive(tabID: $0.tabs[0].id) }
        await phone.sync()
        #expect(phone.engine.state == .failed("offline"))
        await cloud.fail(with: nil)
        await phone.relaunch(cloud: cloud)
        await phone.sync()
        await mac.sync()
        #expect(phone.state.tabs.isEmpty)
        #expect(mac.state.tabs.isEmpty)
        #expect(mac.state.archived.count == 1)
    }

    @Test func aLostStateFileComesBackFromTheSession() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file), mac = Device(cloud: cloud, keys: keychain)
        phone.engine.start()
        mac.engine.start()
        phone.change { state in
            state.addSpace(name: "Work")
            _ = state.openTab(url: url("a"))
        }
        await phone.sync()
        await mac.sync()
        let before = mac.state.shared

        await phone.engine.finish()
        phone.state = BrowserState()
        await phone.relaunch(cloud: cloud)
        await phone.sync()
        await mac.sync()
        #expect(phone.state.shared == before)
        #expect(mac.state.shared == before)
    }

    @Test func aDeviceWithoutTheKeyWaitsAndChangesNothing() async {
        let phone = Device(cloud: cloud), mac = Device(cloud: cloud)
        phone.engine.start()
        phone.change { _ = $0.openTab(url: url("a")) }
        await phone.sync()
        let stored = await cloud.stored

        mac.change { _ = $0.openTab(url: url("mac")) }
        mac.engine.start()
        await mac.sync()
        #expect(mac.engine.state == .waitingForKey)
        #expect(mac.state.tabs.compactMap(\.url) == [url("mac")])
        #expect(await cloud.stored == stored)
        #expect(try! mac.keys.keys().isEmpty)

        // iCloud Keychain brings it.
        mac.keys.share(with: phone.keys)
        await mac.sync()
        await phone.sync()
        #expect(mac.engine.state == .idle)
        #expect(Set(phone.state.tabs.compactMap(\.url)) == [url("a"), url("mac")])
        #expect(mac.state.shared == phone.state.shared)
    }

    @Test func twoDevicesThatEachMadeAKeyAgreeOnTheFirst() async {
        let phone = Device(cloud: cloud), mac = Device(cloud: cloud)
        // The phone is first to name its key.
        phone.engine.start()
        await phone.sync()
        mac.engine.start()
        // Both have something to send before either's key has reached the other.
        await cloud.holdSends()
        phone.change { _ = $0.openTab(url: url("phone")) }
        mac.change { _ = $0.openTab(url: url("mac")) }
        async let first: Void = phone.sync()
        await mac.sync()
        #expect(mac.engine.state == .waitingForKey)
        await cloud.release()
        await first

        mac.keys.share(with: phone.keys)
        await mac.sync()
        await phone.sync()
        #expect(mac.state.shared == phone.state.shared)
        #expect(phone.state.tabs.count == 2)
        let keyIDs = Set(await cloud.stored.values.map(\.keyID))
        #expect(keyIDs == [try! phone.keys.keys()[0].id])
    }

    @Test func noAccountIsReportedAndRecovered() async {
        let (phone, _) = pair()
        await cloud.fail(with: .noAccount)
        phone.change { _ = $0.openTab(url: url("a")) }
        await phone.sync()
        #expect(phone.engine.state == .noAccount)
        await cloud.fail(with: nil)
        await phone.sync()
        #expect(phone.engine.state == .idle)
        #expect(await cloud.stored.count == 5)
    }

    @Test func anEmptiedCloudIsFilledAgainNotObeyed() async {
        let (phone, mac) = pair()
        phone.change { state in
            state.addSpace(name: "Work")
            _ = state.openTab(url: url("a"))
        }
        await phone.sync()
        await mac.sync()
        let before = phone.state.shared

        await cloud.empty()
        await cloud.expireTokens()
        await phone.sync()
        await mac.sync()
        #expect(phone.state.shared == before)
        #expect(mac.state.shared == before)
        #expect(await cloud.stored.count == 6)
    }

    @Test func anExpiredTokenFetchesEverythingAndFindsWhatWasDeleted() async {
        let (phone, mac) = pair()
        phone.change { state in
            _ = state.openTab(url: url("a"))
            _ = state.openTab(url: url("b"))
        }
        await phone.sync()
        await mac.sync()
        phone.change { $0.archive(tabID: $0.tabs[0].id) }
        await phone.sync()
        await cloud.expireTokens()
        await mac.sync()
        #expect(mac.state.shared == phone.state.shared)
        #expect(mac.state.tabs.count == 1)
    }

    @Test func turningSyncOffForgetsTheSessionAndKeepsTheState() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file)
        phone.engine.start()
        phone.change { _ = $0.openTab(url: url("a")) }
        await phone.engine.finish()
        #expect(FileManager.default.fileExists(atPath: file.path))

        phone.engine.stop()
        await phone.engine.finish()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(phone.engine.state == .disabled)
        phone.change { $0.archive(tabID: $0.tabs[0].id) }
        await phone.sync()
        #expect(await cloud.stored.count == 5)

        // Back on: the tab closed while it was off is still in the cloud, and comes back.
        phone.engine.start()
        await phone.sync()
        #expect(phone.state.tabs.count == 1)
    }

    @Test func aTabClosedWhileItWasOnItsWayUpStaysClosed() async {
        let (phone, mac) = pair()
        await cloud.holdSends()
        phone.change { _ = $0.openTab(url: url("a"), title: "A") }
        async let sending: Void = phone.sync()
        while await cloud.sendCount == 0 { await Task.yield() }
        phone.change { $0.drop(tabID: $0.tabs[0].id) }
        await cloud.release()
        await sending
        await phone.sync()
        await mac.sync()
        #expect(phone.state.tabs.isEmpty)
        #expect(mac.state.tabs.isEmpty)
        // Home, the default profile, two lists.
        #expect(await cloud.stored.count == 4)
    }

    @Test func startingFreshBringsNothingBackFromAnOldSession() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file), mac = Device(cloud: cloud, keys: keychain)
        phone.engine.start()
        mac.engine.start()
        phone.change { state in
            _ = state.openTab(url: url("kept"))
            _ = state.openTab(url: url("closed-later"))
        }
        await phone.sync()
        await mac.sync()
        await phone.engine.finish()

        // The phone is away; the Mac closes a tab for good. Then the phone's state file turns out
        // unreadable, and it starts fresh with its old session still on disk.
        mac.change { state in
            let tab = state.tabs.first { $0.url == url("closed-later") }!
            state.drop(tabID: tab.id)
        }
        await mac.sync()
        let restarted = Device(cloud: cloud, keys: keychain, fileURL: file)
        restarted.engine.start(fresh: true)
        await restarted.sync()
        await mac.sync()
        #expect(restarted.state.tabs.compactMap(\.url) == [url("kept")])
        #expect(mac.state.tabs.compactMap(\.url) == [url("kept")])
    }

    @Test func titlesAndViewsAloneAreMinorChanges() async {
        let (phone, _) = pair()
        phone.change { _ = $0.openTab(url: url("a"), title: "A") }
        #expect(await !phone.engine.pendingIsMinor(phone.state.shared))
        await phone.sync()
        phone.change { $0.update(tabID: $0.tabs[0].id, url: url("a"), title: "(1) A") }
        phone.change { $0.markViewed(tabID: $0.tabs[0].id) }
        #expect(await phone.engine.pendingIsMinor(phone.state.shared))
        phone.change { $0.update(tabID: $0.tabs[0].id, url: url("b"), title: "B") }
        #expect(await !phone.engine.pendingIsMinor(phone.state.shared))
    }

    @Test func changesMadeDuringASendGoOutInTheNextRound() async {
        let (phone, mac) = pair()
        phone.change { _ = $0.openTab(url: url("a"), title: "A") }
        await cloud.holdSends()
        async let sending: Void = phone.sync()
        while await cloud.sendCount == 0 { await Task.yield() }
        phone.change { _ = $0.openTab(url: url("b"), title: "B") }
        await cloud.release()
        await sending
        await phone.sync()
        await mac.sync()
        #expect(Set(mac.state.tabs.map(\.title)) == ["A", "B"])
    }

    // MARK: Changes made while a round is out

    private func closing(_ path: String) -> (inout BrowserState) -> Void {
        { state in
            if let tab = state.tabs.first(where: { $0.url == url(path) }) { state.drop(tabID: tab.id) }
        }
    }

    /// Two devices with "stays" and "closes" open, the Mac's news waiting for the phone (a tab
    /// renamed, another opened), and a tab of the phone's own to send.
    private func pairWithNewsBothWays() async -> (Device, Device) {
        let (phone, mac) = pair()
        phone.change { state in
            _ = state.openTab(url: url("stays"), title: "Stays")
            _ = state.openTab(url: url("closes"), title: "Closes")
        }
        await phone.sync()
        await mac.sync()
        mac.change { state in
            state.update(tabID: state.tabs.first { $0.url == url("stays") }!.id, url: url("stays"), title: "Renamed")
            _ = state.openTab(url: url("new"), title: "New")
        }
        await mac.sync()
        phone.change { _ = $0.openTab(url: url("mine"), title: "Mine") }
        return (phone, mac)
    }

    private func expectClosedAndNothingElseLost(_ phone: Device, _ mac: Device) async {
        #expect(Set(phone.state.tabs.map(\.title)) == ["Renamed", "New", "Mine"])
        for _ in 0..<2 {
            await phone.sync()
            await mac.sync()
        }
        #expect(Set(phone.state.tabs.map(\.title)) == ["Renamed", "New", "Mine"])
        #expect(mac.state.shared == phone.state.shared)
        // Home, the default profile, two lists, three tabs.
        #expect(await cloud.stored.count == 7)
    }

    /// The engine reads the state several times a round, and the work between two reads is done off
    /// the main thread: the user can change something at any of them. A round that merges and sends
    /// without a retry reads it ten times.
    @Test(arguments: 1...10)
    func aTabClosedAtAnyPointOfARoundStaysClosedAndNothingElseIsLost(read: Int) async {
        let (phone, mac) = await pairWithNewsBothWays()
        phone.change(atRead: read, closing("closes"))
        await phone.sync()
        #expect(phone.madeEveryEdit)
        await expectClosedAndNothingElseLost(phone, mac)
    }

    @Test func aTabClosedBetweenAMergeBeingAppliedAndTheSessionTakingItStaysClosed() async {
        let (phone, mac) = await pairWithNewsBothWays()
        await phone.engine.worker.setAfterApplyForTesting { @MainActor [self] in
            guard phone.state.tabs.contains(where: { $0.url == url("new") }) else { return }
            phone.change(closing("closes"))
            // Noted before the session takes the merge.
            _ = await phone.engine.pendingIsMinor(phone.state.shared)
        }
        await phone.sync()
        await phone.engine.worker.setAfterApplyForTesting(nil)
        #expect(!phone.state.tabs.contains { $0.url == url("closes") })
        await expectClosedAndNothingElseLost(phone, mac)
    }

    /// Three merges in a row find the state changed (a page that keeps changing its title): the next
    /// is made where nothing can change meanwhile.
    @Test func aStateThatKeepsChangingForAWhileStillSyncsInOneRound() async {
        let (phone, mac) = await pairWithNewsBothWays()
        // The reads at which each of the first three merges is applied.
        for (index, read) in [3, 5, 7].enumerated() {
            phone.change(atRead: read) { state in
                let tab = state.tabs.first { $0.url == url("mine") }!
                state.update(tabID: tab.id, url: url("mine"), title: "Mine \(index)")
            }
        }
        // And one more as that one starts: it's told of a change the session hasn't noted, and waits.
        phone.change(atRead: 9, closing("closes"))
        await phone.sync()
        #expect(phone.madeEveryEdit)
        #expect(phone.engine.state == .idle)
        #expect(Set(phone.state.tabs.map(\.title)) == ["Renamed", "New", "Mine 2"])
        await mac.sync()
        #expect(mac.state.shared == phone.state.shared)
    }

    /// 0: closed in the same turn sync was started in. 1 to 3: at each read of the first round, which
    /// is where what the state lost is restored from the session.
    @Test(arguments: 0...3)
    func aTabClosedRightAfterLaunchIsNotBroughtBackFromTheSession(read: Int) async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file), mac = Device(cloud: cloud, keys: keychain)
        phone.engine.start()
        mac.engine.start()
        phone.change { _ = $0.openTab(url: url("a")) }
        await phone.sync()
        await mac.sync()

        // Offline, so only the session can bring it back.
        await cloud.fail(with: .failed("offline"))
        await phone.relaunch(cloud: cloud)
        if read == 0 {
            phone.change(closing("a"))
        } else {
            phone.change(atRead: read, closing("a"))
        }
        await phone.sync()
        #expect(phone.madeEveryEdit)
        #expect(phone.state.tabs.isEmpty)
        await cloud.fail(with: nil)
        await phone.sync()
        await mac.sync()
        #expect(phone.state.tabs.isEmpty)
        #expect(mac.state.tabs.isEmpty)
    }

    @Test func aStateThatNeverStopsChangingFailsTheRoundAndLosesNothing() async {
        let (phone, mac) = pair()
        mac.change { _ = $0.openTab(url: url("theirs")) }
        await mac.sync()
        phone.changesAtEveryRead = { state in _ = state.openTab(url: url("mine-\(state.tabs.count)")) }
        await phone.sync()
        #expect(phone.engine.state == .failed("Couldn't finish syncing. It will try again."))
        phone.changesAtEveryRead = nil
        let mine = phone.state.tabs.compactMap(\.url).filter { $0 != url("theirs") }
        #expect(!mine.isEmpty)
        await phone.sync()
        await mac.sync()
        #expect(Set(phone.state.tabs.compactMap(\.url)) == Set(mine + [url("theirs")]))
        #expect(mac.state.shared == phone.state.shared)
    }

    // MARK: Folders

    /// How many folder records the cloud holds: Home, the default profile, the two lists and `tabs`
    /// tabs are the rest.
    private func foldersInTheCloud(tabs: Int) async -> Int { await cloud.stored.count - 4 - tabs }

    @Test func aFolderAndWhatIsInItCross() async {
        let (phone, mac) = pair()
        phone.change { state in
            let a = state.openTab(url: url("a")), b = state.openTab(url: url("b"))
            let folder = state.newFolder(with: a.id, name: "Trip")!
            _ = state.addToFolder(b.id, folder.id)
            state.setFolderIcon(folder.id, "airplane")
        }
        await phone.sync()
        await mac.sync()
        #expect(mac.state.shared == phone.state.shared)
        let folder = mac.state.folders[0]
        #expect((folder.name, folder.icon) == ("Trip", "airplane"))
        #expect(mac.state.tabs(inFolder: folder.id).count == 2)

        mac.change { $0.renameFolder(folder.id, to: "Lisbon") }
        await mac.sync()
        await phone.sync()
        #expect(phone.state.folders.map(\.name) == ["Lisbon"])
    }

    @Test func aPinnedFolderKeepsItsPlaceAcrossDevices() async {
        let (phone, mac) = pair()
        phone.change { state in
            let a = state.openTab(url: url("a"))
            let folder = state.newFolder(with: a.id)!
            state.moveFolder(folder.id, toPinned: true)
        }
        await phone.sync()
        await mac.sync()
        #expect(mac.state.shared == phone.state.shared)
        #expect(mac.state.isPinnedFolder(mac.state.folders[0].id))
        #expect(mac.state.tabs[0].pinPlace == .list)
    }

    @Test func anEmptiedFolderGoesEverywhereAndFromTheCloud() async {
        let (phone, mac) = pair()
        phone.change { state in
            let a = state.openTab(url: url("a"))
            _ = state.newFolder(with: a.id)
        }
        await phone.sync()
        await mac.sync()
        #expect(await foldersInTheCloud(tabs: 1) == 1)

        phone.change { $0.removeFromFolder($0.tabs[0].id) }
        #expect(phone.state.folders.isEmpty)
        await phone.sync()
        await mac.sync()
        #expect(mac.state.folders.isEmpty)
        #expect(mac.state.tabs.map(\.folderID) == [nil])
        #expect(await foldersInTheCloud(tabs: 1) == 0)
        await phone.sync()
        #expect(phone.state.shared == mac.state.shared)
    }

    @Test func aTabPutInAFolderAsItEmptiesElsewhereKeepsItsFolder() async {
        let (phone, mac) = pair()
        phone.change { state in
            let a = state.openTab(url: url("a"))
            _ = state.newFolder(with: a.id, name: "Trip")
            _ = state.openTab(url: url("b"))
        }
        await phone.sync()
        await mac.sync()
        let folder = phone.state.folders[0]
        let a = phone.state.tabs.first { $0.url == url("a") }!, b = phone.state.tabs.first { $0.url == url("b") }!

        // The phone takes the folder's only tab out; the Mac, not knowing, puts the other one in.
        phone.change { $0.removeFromFolder(a.id) }
        mac.change { _ = $0.addToFolder(b.id, folder.id) }
        await phone.sync()
        await mac.sync()
        await phone.sync()
        await mac.sync()
        #expect(phone.state.shared == mac.state.shared)
        #expect(phone.state.folders.map(\.name) == ["Trip"])
        #expect(phone.state.tab(b.id)?.folderID == folder.id)
        #expect(phone.state.tab(a.id)?.folderID == nil)
        #expect(await foldersInTheCloud(tabs: 2) == 1)
    }

    @Test func aFolderDeletedFromTheCloudWhileInUseGoesBackUp() async {
        let (phone, mac) = pair()
        phone.change { state in
            let a = state.openTab(url: url("a"))
            _ = state.newFolder(with: a.id, name: "Trip")
            _ = state.openTab(url: url("b"))
        }
        await phone.sync()
        await mac.sync()
        let folder = phone.state.folders[0]
        let a = phone.state.tabs.first { $0.url == url("a") }!, b = phone.state.tabs.first { $0.url == url("b") }!

        // The phone empties the folder and its record is deleted before the Mac says it put a tab in.
        phone.change { $0.removeFromFolder(a.id) }
        await phone.sync()
        #expect(await foldersInTheCloud(tabs: 2) == 0)
        mac.change { _ = $0.addToFolder(b.id, folder.id) }
        await mac.sync()
        await phone.sync()
        await mac.sync()
        #expect(mac.state.tab(b.id)?.folderID == folder.id)
        #expect(phone.state.shared == mac.state.shared)
        #expect(phone.state.folders.map(\.name) == ["Trip"])
        #expect(await foldersInTheCloud(tabs: 2) == 1)
    }

    @Test func aFolderOnlyABlankTabIsInStaysOnItsDevice() async {
        let (phone, mac) = pair()
        phone.change { state in
            let blank = state.openTab(url: nil)
            _ = state.newFolder(with: blank.id, name: "Later")
            _ = state.openTab(url: url("a"))
        }
        await phone.sync()
        await mac.sync()
        #expect(mac.state.folders.isEmpty)
        #expect(await foldersInTheCloud(tabs: 1) == 0)

        // A change from the Mac leaves the folder and its blank tab as they are.
        mac.change { _ = $0.openTab(url: url("b")) }
        await mac.sync()
        await phone.sync()
        #expect(phone.state.folders.map(\.name) == ["Later"])
        #expect(phone.state.tabs.contains { $0.url == nil && $0.folderID == phone.state.folders[0].id })
    }

    @Test func anArchivedFolderComesBackWholeOnTheOtherDevice() async {
        let (phone, mac) = pair()
        phone.change { state in
            let a = state.openTab(url: url("a")), b = state.openTab(url: url("b"))
            let folder = state.newFolder(with: a.id, name: "Trip")!
            _ = state.addToFolder(b.id, folder.id)
        }
        await phone.sync()
        await mac.sync()
        phone.change { _ = $0.closeFolder($0.folders[0].id) }
        await phone.sync()
        await mac.sync()
        #expect(mac.state.tabs.isEmpty && mac.state.folders.isEmpty)
        // Two archive entries, and no folder's record.
        #expect(mac.state.archived.count == 2)
        #expect(await foldersInTheCloud(tabs: 2) == 0)

        guard let archived = mac.state.archived.first else { return }
        mac.change { _ = $0.restore(archivedID: archived.id) }
        await mac.sync()
        await phone.sync()
        #expect(phone.state.shared == mac.state.shared)
        #expect(phone.state.folders.map(\.name) == mac.state.folders.map(\.name))
    }

    @Test func aLostStateGetsItsFoldersBack() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file)
        phone.engine.start()
        phone.change { state in
            let a = state.openTab(url: url("a"))
            _ = state.newFolder(with: a.id, name: "Trip")
        }
        await phone.sync()

        phone.state = BrowserState()
        await phone.relaunch(cloud: cloud)
        await phone.sync()
        #expect(phone.state.folders.map(\.name) == ["Trip"])
        #expect(phone.state.tabs.map(\.folderID) == [phone.state.folders[0].id])
        #expect(await foldersInTheCloud(tabs: 1) == 1)
    }

    @Test func aFolderWhoseOnlyTabIsTooBigToSendStaysOnItsDevice() async {
        let (phone, mac) = pair()
        phone.change { state in
            let huge = state.openTab(url: URL(string: "data:text/plain," + String(repeating: "a", count: 1_000_000))!)
            _ = state.newFolder(with: huge.id, name: "Big")
        }
        await phone.sync()
        await mac.sync()
        #expect(await foldersInTheCloud(tabs: 0) == 0)

        // Nothing goes back and forth after that.
        let sends = await cloud.sendCount
        for _ in 0..<3 {
            await mac.sync()
            await phone.sync()
        }
        #expect(await cloud.sendCount == sends)
        #expect(phone.state.folders.map(\.name) == ["Big"])
    }

    @Test func turningSyncOffMidRoundLeavesNoStatusAndNoSessionBehind() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file)
        phone.engine.start()
        await phone.sync()
        phone.change { _ = $0.openTab(url: url("a")) }
        await cloud.holdSends()
        async let round: Void = phone.sync()
        while await cloud.sendCount == 1 { await Task.yield() }
        phone.engine.stop()
        await cloud.release()
        await round
        await phone.engine.finish()
        #expect(phone.engine.state == .disabled)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func turnedOffAndStraightBackOnItJoinsAsANewDevice() async {
        let file = temporaryFile()
        let phone = Device(cloud: cloud, keys: keychain, fileURL: file)
        phone.engine.start()
        phone.change { state in
            _ = state.openTab(url: url("a"))
            _ = state.openTab(url: url("b"))
        }
        await phone.sync()
        await phone.engine.finish()
        await cloud.empty()

        // A write of the session is still waiting when sync goes off, so its file is still there
        // when sync comes back on: read back, it would restore both tabs.
        phone.holdsSaves = true
        phone.change(closing("b"))
        _ = await phone.engine.pendingIsMinor(phone.state.shared)
        phone.engine.stop()
        phone.change(closing("a"))
        phone.engine.start()
        for _ in 0..<200 { await Task.yield() }
        phone.releaseSaves()
        await phone.sync()
        #expect(phone.state.tabs.isEmpty)
        #expect(await cloud.stored.count == 4)
    }
}
