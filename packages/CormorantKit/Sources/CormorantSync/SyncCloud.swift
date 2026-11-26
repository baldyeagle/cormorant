import Foundation

/// What a fetch brings.
public struct SyncCloudChanges: Sendable, Equatable {
    public var records: [SealedRecord]
    /// Names of records deleted since the token.
    public var deleted: [String]
    /// Where the next fetch continues from.
    public var token: Data?
    /// Fetched from the start, not from a token: `records` is everything the cloud has.
    public var isEverything: Bool

    public init(records: [SealedRecord] = [], deleted: [String] = [], token: Data? = nil, isEverything: Bool = false) {
        self.records = records
        self.deleted = deleted
        self.token = token
        self.isEverything = isEverything
    }
}

/// How a send went, record by record. A record in none of these failed some other way and is sent again.
public struct SyncSendResult: Sendable, Equatable {
    /// Saved: each name's new tag.
    public var saved: [String: Data]
    /// Refused: the cloud's copy is newer than the tag sent. Its copy, to merge with.
    public var conflicts: [SealedRecord]
    /// Refused: the cloud deleted the record since.
    public var gone: [String]
    /// Deleted (or already gone).
    public var deleted: [String]

    public init(saved: [String: Data] = [:], conflicts: [SealedRecord] = [], gone: [String] = [], deleted: [String] = []) {
        self.saved = saved
        self.conflicts = conflicts
        self.gone = gone
        self.deleted = deleted
    }
}

public enum SyncCloudError: Error, Equatable, Sendable {
    /// Not signed into iCloud.
    case noAccount
    /// The token is too old to continue from: fetch from the start.
    case tokenExpired
    case failed(String)
}

/// The cloud: CloudKit's private database in the app (`CloudKitSyncCloud`), a fake in tests. It only
/// ever sees sealed records.
public protocol SyncCloud: Sendable {
    /// Every change since `token`, or everything the cloud has when it's nil. An emptied or brand-new
    /// cloud gives nothing, as everything.
    func fetch(since token: Data?) async throws -> SyncCloudChanges
    /// Saves and deletes, each on its own: one refusal doesn't stop the rest.
    func send(saves: [SealedRecord], deletes: [String]) async throws -> SyncSendResult
    /// The ID of the key the devices agreed to encrypt with, nil when none has said.
    func keyID() async throws -> String?
    /// Says this device's key is the one, unless another device said first. Returns the one it is.
    func announce(keyID: String) async throws -> String
}

/// Where the keys are kept: iCloud Keychain in the app (`KeychainSyncKeyStore`), a fake in tests.
public protocol SyncKeyStore: Sendable {
    func keys() throws -> [SyncKey]
    func add(_ key: SyncKey) throws
}
