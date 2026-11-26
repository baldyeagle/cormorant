import CormorantSync
import Foundation

/// A cloud in memory that behaves as CloudKit does where sync depends on it: a save is refused unless
/// it carries the tag of the cloud's latest copy, changes are fetched from a token, and the first
/// device to name a key wins. Several engines sharing one are several devices.
public actor FakeSyncCloud: SyncCloud {
    private var records: [String: SealedRecord] = [:]
    /// Every save and delete, in order: a token is a place in it.
    private var log: [(name: String, deleted: Bool)] = []
    private var version = 0
    private var key: String?
    private var error: SyncCloudError?
    private var held: [CheckedContinuation<Void, Never>]?
    public private(set) var fetchCount = 0
    public private(set) var sendCount = 0

    public init() {}

    /// What's stored, by name: sealed, as Apple would see it.
    public var stored: [String: SealedRecord] { records }

    /// Every call fails with `error` until it's set back to nil.
    public func fail(with error: SyncCloudError?) { self.error = error }

    /// Sends wait until `release()`.
    public func holdSends() { held = [] }

    public func release() {
        let waiting = held ?? []
        held = nil
        for continuation in waiting { continuation.resume() }
    }

    /// The user deleted the app's iCloud data: everything goes, the key's name too.
    public func empty() {
        records = [:]
        log = []
        key = nil
    }

    /// Every token so far is too old.
    public func expireTokens() { epoch += 1 }
    private var epoch = 0

    private func token(at index: Int) -> Data { Data("\(epoch):\(index)".utf8) }

    public func fetch(since token: Data?) async throws -> SyncCloudChanges {
        fetchCount += 1
        if let error { throw error }
        guard let token else {
            return SyncCloudChanges(records: Array(records.values), token: self.token(at: log.count), isEverything: true)
        }
        let parts = String(decoding: token, as: UTF8.self).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] == epoch, parts[1] <= log.count else { throw SyncCloudError.tokenExpired }
        var changed = Set<String>()
        for entry in log[parts[1]...] { changed.insert(entry.name) }
        return SyncCloudChanges(records: changed.compactMap { records[$0] },
                                deleted: changed.filter { records[$0] == nil },
                                token: self.token(at: log.count))
    }

    public func send(saves: [SealedRecord], deletes: [String]) async throws -> SyncSendResult {
        sendCount += 1
        if held != nil { await withCheckedContinuation { held?.append($0) ?? $0.resume() } }
        if let error { throw error }
        var result = SyncSendResult()
        for var record in saves {
            if let existing = records[record.name] {
                guard existing.tag == record.tag else {
                    result.conflicts.append(existing)
                    continue
                }
            } else if record.tag != nil {
                result.gone.append(record.name)
                continue
            }
            version += 1
            record.tag = Data("v\(version)".utf8)
            records[record.name] = record
            log.append((record.name, false))
            result.saved[record.name] = record.tag
        }
        for name in deletes {
            if records.removeValue(forKey: name) != nil { log.append((name, true)) }
            result.deleted.append(name)
        }
        return result
    }

    public func keyID() async throws -> String? {
        if let error { throw error }
        return key
    }

    public func announce(keyID: String) async throws -> String {
        if let error { throw error }
        if key == nil { key = keyID }
        return key!
    }
}

/// A keychain in memory. Two devices given the same one share keys, as iCloud Keychain's do; given
/// one each, a key only crosses when `share(with:)` says it has.
public final class FakeSyncKeyStore: SyncKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncKey] = []

    public init() {}

    public func keys() throws -> [SyncKey] { lock.withLock { stored } }

    public func add(_ key: SyncKey) throws {
        lock.withLock { if !stored.contains(key) { stored.append(key) } }
    }

    /// iCloud Keychain caught up: each store has the other's keys.
    public func share(with other: FakeSyncKeyStore) {
        let mine = lock.withLock { stored }
        let theirs = other.lock.withLock { other.stored }
        for key in theirs { try? add(key) }
        for key in mine { try? other.add(key) }
    }
}
