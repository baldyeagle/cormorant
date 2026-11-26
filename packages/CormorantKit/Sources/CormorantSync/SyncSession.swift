import CormorantCore
import Foundation

/// Everything sync remembers between launches, saved next to the state: the ledger, where fetching
/// got to, and each cloud record's tag. Turns fetched changes into a merged state and the state's
/// changes into sealed records.
public struct SyncSession: Codable, Sendable, Equatable {
    public internal(set) var ledger = SyncLedger()
    var token: Data?
    /// By the record's name in the cloud.
    var tags: [String: Data] = [:]
    /// Names of cloud records this build can't read (a newer format, or damaged). They're left alone:
    /// never merged, never saved over.
    var unreadable: Set<String> = []

    public init() {}

    static let largestPayload = 900_000

    /// What `outgoing` made, kept to tell what the cloud took.
    public struct Outgoing: Sendable {
        public var saves: [SealedRecord] = []
        public var deletes: [String] = []
        var records: [String: (id: SyncRecordID, record: SyncRecord)] = [:]
        var deletedIDs: [String: SyncRecordID] = [:]
        public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
    }

    /// Merges fetched changes into `local` and returns the result. Throws `SyncCipherError.missingKey`,
    /// changing nothing, when a record needs a key that isn't in `keys`: the fetch is taken again once
    /// the key is here.
    ///
    /// When the fetch is everything the cloud has, what it doesn't have was deleted there. Unless it
    /// has nothing at all: then it was emptied, or is new, and everything here goes up as new.
    public mutating func take(_ changes: SyncCloudChanges, keys: [SyncKey], local: BrowserState.Shared) throws -> BrowserState.Shared {
        var saves: SyncSnapshot = [:]
        var newTags: [String: Data] = [:], readable = Set<String>(), newlyUnreadable = Set<String>()
        for sealed in changes.records {
            do {
                let opened = try SyncCipher.open(sealed, with: keys)
                saves[opened.id] = opened.record
                newTags[sealed.name] = sealed.tag
                readable.insert(sealed.name)
            } catch let error as SyncCipherError {
                if case .missingKey = error { throw error }
                newlyUnreadable.insert(sealed.name)
            }
        }
        let ids = Dictionary(ledger.baseline.keys.map { (SyncCipher.name(for: $0), $0) }) { first, _ in first }
        var deletes = Set(changes.deleted.compactMap { ids[$0] })
        for name in changes.deleted {
            tags[name] = nil
            unreadable.remove(name)
        }
        if changes.isEverything {
            if changes.records.isEmpty {
                ledger.forgetCloud()
                tags = [:]
                unreadable = []
                deletes = []
            } else {
                let present = readable.union(newlyUnreadable)
                for (name, id) in ids where !present.contains(name) {
                    deletes.insert(id)
                    tags[name] = nil
                }
                unreadable.formIntersection(present)
            }
        }
        tags.merge(newTags) { $1 }
        unreadable.subtract(readable)
        unreadable.formUnion(newlyUnreadable)
        token = changes.token
        return ledger.receive(saves: saves, deletes: deletes, local: local)
    }

    /// What `local` has to send, sealed with `key`.
    public func outgoing(local: BrowserState.Shared, key: SyncKey) throws -> Outgoing {
        let changes = ledger.pendingChanges(local: local)
        var outgoing = Outgoing()
        for (id, record) in changes.saves {
            let name = SyncCipher.name(for: id)
            guard !unreadable.contains(name) else { continue }
            let sealed = try SyncCipher.seal(record, id: id, with: key, tag: tags[name])
            // CloudKit takes records up to 1 MB, and one it refuses holds up the others sent with it.
            // Only a tab on an enormous `data:` address gets there; it stays on this device.
            guard sealed.payload.count <= Self.largestPayload else { continue }
            outgoing.saves.append(sealed)
            outgoing.records[name] = (id, record)
        }
        // A folder only goes with a tab that's in it: sent alone (its tab too big to send, or waiting),
        // the other devices would delete it as unused, and this one would send it again, forever.
        var used = Set<SyncRecordID>()
        let tabs = ledger.baseline.filter { $0.key.kind == .tab }.map { ($0.key, $0.value) }
            + outgoing.records.values.filter { $0.id.kind == .tab }.map { ($0.id, $0.record) }
        for (id, record) in tabs { used.formUnion(record.requirements(id: id)) }
        for (name, sent) in outgoing.records where sent.id.kind == .folder && !used.contains(sent.id) {
            outgoing.records[name] = nil
            outgoing.saves.removeAll { $0.name == name }
        }
        for id in changes.deletes {
            let name = SyncCipher.name(for: id)
            outgoing.deletes.append(name)
            outgoing.deletedIDs[name] = id
        }
        return outgoing
    }

    /// Takes the cloud's answer to `outgoing`: what it took is no longer pending, and what it refused
    /// is merged with its copy (and goes out again as merged). Returns `local` with those merges.
    public mutating func took(_ result: SyncSendResult, of outgoing: Outgoing, keys: [SyncKey],
                              local: BrowserState.Shared) throws -> BrowserState.Shared {
        let here = SyncSnapshot.ids(of: local)
        for (name, tag) in result.saved {
            guard let sent = outgoing.records[name] else { continue }
            tags[name] = tag
            ledger.sent(sent.id, sent.record, stillHere: here.contains(sent.id))
        }
        for name in result.deleted {
            guard let id = outgoing.deletedIDs[name] else { continue }
            tags[name] = nil
            ledger.deleted(id)
        }
        var conflicts = SyncCloudChanges(records: result.conflicts, deleted: result.gone, token: token)
        // A record the cloud deleted that this device never knew it had: nothing to delete here, and
        // it goes up again as new.
        conflicts.deleted.removeAll { name in
            guard let sent = outgoing.records[name], ledger.baseline[sent.id] == nil else { return false }
            tags[name] = nil
            return true
        }
        guard !conflicts.records.isEmpty || !conflicts.deleted.isEmpty else { return local }
        return try take(conflicts, keys: keys, local: local)
    }
}
