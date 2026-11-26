import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// The cloud for real: one zone in the CloudKit private database of the iCloud account the device is
/// signed into. Each record is an `Item` with a key ID (`k`), a format (`v`) and ciphertext (`d`); the
/// one `Key` record names the key the devices agreed on. Nothing here can be tested without iCloud, so
/// it only translates: every decision is the engine's.
public actor CloudKitSyncCloud: SyncCloud {
    public static let containerIdentifier = "iCloud.dev.baldyeagle.cormorant"

    /// Whether this build may use CloudKit at all. Making a container without the iCloud entitlement
    /// (a build with signing off) stops the app, so ask first. The iOS simulator's builds are unsigned.
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        return true
        #endif
    }

    private let containerIdentifier: String
    /// Made at the first call, so nothing touches CloudKit while sync is off.
    private lazy var database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "Sync", ownerName: CKCurrentUserDefaultName)
    private var keyRecordID: CKRecord.ID { CKRecord.ID(recordName: "key", zoneID: zoneID) }
    private var isSubscribed = false
    private static let subscribedKey = "syncZoneSubscribed"
    private static let itemType = "Item"
    private static let keyType = "Key"
    /// CloudKit takes at most 400 records in one request.
    private static let batchSize = 300

    public init(containerIdentifier: String = CloudKitSyncCloud.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public func fetch(since token: Data?) async throws -> SyncCloudChanges {
        var changes = SyncCloudChanges(isEverything: token == nil)
        var serverToken: CKServerChangeToken?
        if let token {
            guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
                throw SyncCloudError.tokenExpired
            }
            serverToken = decoded
        }
        do {
            var moreComing = true
            while moreComing {
                let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
                for (_, result) in page.modificationResultsByID {
                    switch result {
                    case .success(let modification):
                        if modification.record.recordType == Self.itemType { changes.records.append(Self.sealed(modification.record)) }
                    case .failure(let error):
                        // Not a change to skip (in a fetch of everything it would read as deleted):
                        // the whole fetch is taken again from the same token.
                        throw error
                    }
                }
                for deletion in page.deletions where deletion.recordType == Self.itemType {
                    changes.deleted.append(deletion.recordID.recordName)
                }
                serverToken = page.changeToken
                moreComing = page.moreComing
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Never synced, or the data was deleted in iCloud settings: an empty cloud.
            try await createZone()
            return SyncCloudChanges(isEverything: true)
        } catch let error as CKError where error.code == .changeTokenExpired {
            throw SyncCloudError.tokenExpired
        } catch {
            throw Self.translated(error)
        }
        changes.token = try serverToken.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        await subscribe()
        return changes
    }

    public func send(saves: [SealedRecord], deletes: [String]) async throws -> SyncSendResult {
        var result = SyncSendResult()
        var saves = saves[...], deletes = deletes[...]
        while !saves.isEmpty || !deletes.isEmpty {
            let saving = saves.prefix(Self.batchSize)
            saves = saves.dropFirst(saving.count)
            let deleting = deletes.prefix(Self.batchSize - saving.count)
            deletes = deletes.dropFirst(deleting.count)
            try await send(saving: Array(saving), deleting: Array(deleting), into: &result, retriesZone: true)
        }
        return result
    }

    private func send(saving: [SealedRecord], deleting: [String], into result: inout SyncSendResult,
                      retriesZone: Bool) async throws {
        let records = saving.map(record(for:))
        let ids = deleting.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let saved: [CKRecord.ID: Result<CKRecord, any Error>]
        let deleted: [CKRecord.ID: Result<Void, any Error>]
        do {
            (saved, deleted) = try await database.modifyRecords(saving: records, deleting: ids,
                                                                savePolicy: .ifServerRecordUnchanged, atomically: false)
        } catch let error as CKError where retriesZone && (error.code == .zoneNotFound || error.code == .userDeletedZone) {
            try await createZone()
            return try await send(saving: saving, deleting: deleting, into: &result, retriesZone: false)
        } catch {
            throw Self.translated(error)
        }
        for (id, outcome) in saved {
            switch outcome {
            case .success(let record):
                result.saved[id.recordName] = Self.tag(of: record)
            case .failure(let error as CKError) where error.code == .serverRecordChanged:
                if let server = error.serverRecord { result.conflicts.append(Self.sealed(server)) }
            case .failure(let error as CKError) where error.code == .unknownItem:
                result.gone.append(id.recordName)
            case .failure:
                // Sent again next round.
                break
            }
        }
        for (id, outcome) in deleted {
            switch outcome {
            case .success:
                result.deleted.append(id.recordName)
            case .failure(let error as CKError) where error.code == .unknownItem:
                result.deleted.append(id.recordName)
            case .failure:
                break
            }
        }
    }

    public func keyID() async throws -> String? {
        do {
            return try await database.record(for: keyRecordID)["id"] as? String
        } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
            return nil
        } catch {
            throw Self.translated(error)
        }
    }

    public func announce(keyID: String) async throws -> String {
        let record = CKRecord(recordType: Self.keyType, recordID: keyRecordID)
        record["id"] = keyID
        for attempt in 0..<2 {
            do {
                let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [],
                                                                  savePolicy: .ifServerRecordUnchanged, atomically: false)
                switch saved[keyRecordID] {
                case .success:
                    return keyID
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    // Another device said first.
                    if let theirs = error.serverRecord?["id"] as? String { return theirs }
                    throw SyncCloudError.failed("The cloud's key record can't be read.")
                case .failure(let error as CKError) where attempt == 0 && (error.code == .zoneNotFound || error.code == .userDeletedZone):
                    try await createZone()
                case .failure(let error):
                    throw Self.translated(error)
                case nil:
                    throw SyncCloudError.failed("The cloud didn't answer for the key record.")
                }
            } catch let error as CKError where attempt == 0 && (error.code == .zoneNotFound || error.code == .userDeletedZone) {
                try await createZone()
            } catch let error as SyncCloudError {
                throw error
            } catch {
                throw Self.translated(error)
            }
        }
        throw SyncCloudError.failed("The sync zone couldn't be made.")
    }

    private func createZone() async throws {
        // The zone was missing, so its subscription is too: ask again.
        isSubscribed = false
        UserDefaults.standard.removeObject(forKey: Self.subscribedKey)
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        } catch {
            throw Self.translated(error)
        }
    }

    /// Asks CloudKit for a silent push whenever the zone changes, once. Without it (no push
    /// entitlement, or it failed) sync still runs whenever the app comes to the front.
    private func subscribe() async {
        guard !isSubscribed else { return }
        isSubscribed = true
        let key = Self.subscribedKey
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "sync-zone-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        if (try? await database.save(subscription)) != nil { UserDefaults.standard.set(true, forKey: key) }
    }

    private func record(for sealed: SealedRecord) -> CKRecord {
        var record: CKRecord?
        if let tag = sealed.tag, let coder = try? NSKeyedUnarchiver(forReadingFrom: tag) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder)
            coder.finishDecoding()
        }
        let item = record ?? CKRecord(recordType: Self.itemType, recordID: CKRecord.ID(recordName: sealed.name, zoneID: zoneID))
        item["k"] = sealed.keyID
        item["v"] = Int64(sealed.version)
        item["d"] = sealed.payload
        return item
    }

    private static func sealed(_ record: CKRecord) -> SealedRecord {
        // A record without its fields isn't one of ours as this build knows them: read as a newer format.
        SealedRecord(name: record.recordID.recordName,
                     keyID: record["k"] as? String ?? "",
                     version: (record["v"] as? Int64).map(Int.init) ?? .max,
                     payload: record["d"] as? Data ?? Data(),
                     tag: tag(of: record))
    }

    /// The record's system fields: what CloudKit needs back to tell whether a save is over its latest copy.
    private static func tag(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func translated(_ error: any Error) -> SyncCloudError {
        if let error = error as? SyncCloudError { return error }
        guard let error = error as? CKError else { return .failed(error.localizedDescription) }
        switch error.code {
        case .notAuthenticated: return .noAccount
        case .changeTokenExpired: return .tokenExpired
        case .networkUnavailable, .networkFailure: return .failed("No connection to iCloud.")
        case .quotaExceeded: return .failed("iCloud storage is full.")
        default: return .failed(error.localizedDescription)
        }
    }
}
