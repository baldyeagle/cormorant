import CormorantCore
import Foundation

/// What a device knows of the cloud, and what it still owes it. A value: the app saves it next to the
/// state, and hands it local changes and the cloud's.
///
/// `baseline` is each record as the cloud last had it (fetched, or sent and accepted). A record that
/// differs from it here is waiting to be sent. A record missing here is only ever deleted in the cloud
/// when it was seen being removed while the app ran (`noteLocalChange`): a state that lost records any
/// other way (a new or reset state file, a crash) gets them back (`restoringMissing`) and deletes nothing.
///
/// Folders are the exception both ways. A folder is here exactly while a tab here is in it, so one
/// going isn't a removal to send (the tabs leaving it, or closing, is what's sent), and one the cloud
/// has that no tab is in isn't brought back. The cloud's record of a folder no tab is in any more is
/// deleted once every tab's record says so (`unusedFolders`); if another device was putting a tab in
/// it meanwhile, that device still has the folder and sends it again (`receive`).
public struct SyncLedger: Codable, Sendable, Equatable {
    public private(set) var baseline: SyncSnapshot
    /// Records removed here whose removal the cloud hasn't confirmed.
    public private(set) var pendingDeletes: Set<SyncRecordID>
    /// The cloud's newer copies of records that are here, set aside because what they point at (a
    /// Space, a profile, a folder) hasn't arrived: taken in once it has. Until then the record stays
    /// as it is here, and isn't sent.
    private(set) var deferred: SyncSnapshot
    /// Cloud records that don't read as their kind in this build. They're left alone: not merged, not
    /// saved over, and nothing that points at one comes in.
    private(set) var unreadable: Set<SyncRecordID>

    public init() {
        baseline = [:]
        pendingDeletes = []
        deferred = [:]
        unreadable = []
    }

    private enum CodingKeys: String, CodingKey { case baseline, pendingDeletes, deferred, unreadable }

    // Dictionaries with non-string keys encode as arrays; keep the file a plain object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func snapshot(_ key: CodingKeys) throws -> SyncSnapshot {
            var records: SyncSnapshot = [:]
            for (name, record) in try container.decodeIfPresent([String: SyncRecord].self, forKey: key) ?? [:] {
                if let id = SyncRecordID(name: name) { records[id] = record }
            }
            return records
        }
        func ids(_ key: CodingKeys) throws -> Set<SyncRecordID> {
            Set((try container.decodeIfPresent([String].self, forKey: key) ?? []).compactMap(SyncRecordID.init(name:)))
        }
        baseline = try snapshot(.baseline)
        deferred = try snapshot(.deferred)
        pendingDeletes = try ids(.pendingDeletes)
        unreadable = try ids(.unreadable)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func named(_ records: SyncSnapshot) -> [String: SyncRecord] {
            Dictionary(uniqueKeysWithValues: records.map { ($0.key.name, $0.value) })
        }
        try container.encode(named(baseline), forKey: .baseline)
        try container.encode(named(deferred), forKey: .deferred)
        try container.encode(pendingDeletes.map(\.name).sorted(), forKey: .pendingDeletes)
        try container.encode(unreadable.map(\.name).sorted(), forKey: .unreadable)
    }

    /// What there is to send.
    public struct Changes: Equatable, Sendable {
        public var saves: SyncSnapshot = [:]
        public var deletes: Set<SyncRecordID> = []
        /// Nothing but tabs' titles and when they were last looked at: worth sending, not worth sending
        /// at once (a page can change its title every second).
        public var isMinor = false
        public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
    }

    /// The fields of a tab that change without the user doing anything to it.
    private static let minorFields: Set<String> = ["title", "pinnedTitle", "lastViewedAt"]

    /// The state went from `old` to `new` while the app ran: what's gone was removed by the user (or
    /// by archiving), and is deleted from the cloud. Something that came back (a closed tab reopened)
    /// is no longer.
    public mutating func noteLocalChange(from old: BrowserState.Shared, to new: BrowserState.Shared) {
        let before = SyncSnapshot.ids(of: old), after = SyncSnapshot.ids(of: new)
        pendingDeletes.formUnion(before.subtracting(after).filter { baseline[$0] != nil && $0.kind != .folder })
        pendingDeletes.subtract(after)
    }

    /// `local`'s records as they'd be sent. The two lists keep the place of anything the cloud's list
    /// names that isn't here and wasn't removed here (a record that hasn't arrived, or is waiting for
    /// another, see `receive`), so sending a list never drops it.
    func records(of local: BrowserState.Shared) -> SyncSnapshot {
        var records = SyncSnapshot(local, keeping: baseline)
        let lists: [(SyncRecordID, (UUID) -> SyncRecordID)] = [(.spaceOrder, SyncRecordID.space), (.tabOrder, SyncRecordID.tab)]
        for (list, item) in lists {
            guard let cloud = baseline[list]?.ids, let mine = records[list]?.ids else { continue }
            let here = Set(mine)
            let known = cloud.filter { here.contains($0) || !pendingDeletes.contains(item($0)) }
            let merged = SyncMerge.applying(base: [], theirs: known, onto: mine)
            if merged != mine { records[list]?.fields[SyncRecord.idsField] = .array(merged.map { .string($0.uuidString) }) }
        }
        return records
    }

    /// What `local` has that the cloud doesn't yet, and the removals it hasn't confirmed. Never a
    /// record the cloud's copy of which this build can't read, or has set aside (`deferred`).
    public func pendingChanges(local: BrowserState.Shared) -> Changes {
        let records = records(of: local)
        var changes = Changes(deletes: pendingDeletes.subtracting(records.keys).subtracting(unreadable))
        changes.deletes.formUnion(unusedFolders(records))
        changes.isMinor = changes.deletes.isEmpty
        for (id, record) in records where baseline[id] != record && !unreadable.contains(id) && deferred[id] == nil {
            changes.saves[id] = record
            guard changes.isMinor else { continue }
            if id.kind == .tab, let cloud = baseline[id] {
                let changed = Set(record.fields.keys).union(cloud.fields.keys).filter { record.fields[$0] != cloud.fields[$0] }
                changes.isMinor = changed.isSubset(of: Self.minorFields)
            } else {
                changes.isMinor = false
            }
        }
        if changes.isEmpty { changes.isMinor = false }
        return changes
    }

    /// The cloud's folders that no tab is in: not here (`records` is the state's), and no tab's record
    /// in the cloud, or set aside, names them. None while a tab's record can't be read: it may.
    private func unusedFolders(_ records: SyncSnapshot) -> Set<SyncRecordID> {
        guard !unreadable.contains(where: { $0.kind == .tab }) else { return [] }
        let gone = baseline.keys.filter { $0.kind == .folder && records[$0] == nil && !unreadable.contains($0) }
        guard !gone.isEmpty else { return [] }
        var used = Set<SyncRecordID>()
        for known in [baseline, deferred] {
            for (id, record) in known where id.kind == .tab {
                used.formUnion(record.requirements(id: id).filter { $0.kind == .folder })
            }
        }
        return Set(gone).subtracting(used)
    }

    /// The cloud took `record`. `stillHere` is false when it was removed here while it was on its way
    /// (a tab closed just after it opened): the cloud has it now, so its removal is owed.
    public mutating func sent(_ id: SyncRecordID, _ record: SyncRecord, stillHere: Bool = true) {
        baseline[id] = record
        // Not a folder: one no tab is in goes by `unusedFolders`, once no tab's record names it.
        if !stillHere, id.kind != .folder { pendingDeletes.insert(id) }
    }

    /// The cloud no longer has the record: a removal confirmed.
    public mutating func deleted(_ id: SyncRecordID) {
        forget(id)
    }

    /// The record is gone from the cloud. Its lists stop naming it here, so they don't keep its place.
    private mutating func forget(_ id: SyncRecordID) {
        baseline[id] = nil
        deferred[id] = nil
        unreadable.remove(id)
        pendingDeletes.remove(id)
        guard let dot = id.name.firstIndex(of: "."), id.kind == .space || id.kind == .tab else { return }
        let list: SyncRecordID = id.kind == .space ? .spaceOrder : .tabOrder
        let gone = JSONValue.string(String(id.name[id.name.index(after: dot)...]))
        if case .array(let ids) = baseline[list]?.fields[SyncRecord.idsField], ids.contains(gone) {
            baseline[list]?.fields[SyncRecord.idsField] = .array(ids.filter { $0 != gone })
        }
    }

    /// Takes the cloud's changes (fetched, or what it answered a refused save with) and returns `local`
    /// with them merged in (`SyncMerge`). A record changed on both sides stays pending, as merged. A
    /// record the cloud deleted goes even if it changed here; one removed here stays removed even if it
    /// changed there. Except a folder: deleted in the cloud while a tab here is in it, it stays, and goes
    /// up again as new.
    ///
    /// A record the cloud has that isn't here, and wasn't removed here, comes (back) in: one that was
    /// waiting, or one a state lost without anything seeing it removed.
    ///
    /// Changes can come in any order, over several fetches, so a record waits while what it points at
    /// (`requirements`) isn't here: a new one stays out of the state, and one that's here stays as it
    /// is, the cloud's copy set aside. Otherwise the state would repair the reference (a tab moved to
    /// Home), and the repair would go out as a change. A record that doesn't read as its kind is left
    /// alone the same way.
    public mutating func receive(saves: SyncSnapshot, deletes: Set<SyncRecordID> = [],
                                 local: BrowserState.Shared) -> BrowserState.Shared {
        let mine = records(of: local)
        var records = mine
        for (id, record) in baseline where records[id] == nil && !pendingDeletes.contains(id) { records[id] = record }
        var incoming = deferred
        incoming.merge(saves) { $1 }
        deferred = [:]
        var before: [SyncRecordID: SyncRecord?] = [:]
        for (id, remote) in incoming {
            guard remote.reads(as: id) else {
                unreadable.insert(id)
                if mine[id] == nil { records[id] = nil }
                continue
            }
            unreadable.remove(id)
            before[id] = .some(baseline[id])
            defer { baseline[id] = remote }
            guard !pendingDeletes.contains(id) else { continue }
            if let local = mine[id], local != baseline[id] {
                records[id] = SyncMerge.merge(base: baseline[id], local: local, remote: remote, id: id)
            } else {
                records[id] = remote
            }
        }
        for id in deletes {
            forget(id)
            before[id] = nil
            records[id] = id.kind == .folder ? mine[id] : nil
        }
        var waiting = true
        while waiting {
            waiting = false
            for (id, record) in records where record != mine[id]
                && record.requirements(id: id).contains(where: { records[$0] == nil }) {
                records[id] = mine[id]
                // One that's here: as if its change hadn't come yet.
                if mine[id] != nil, let remote = incoming[id], let previous = before[id] {
                    deferred[id] = remote
                    baseline[id] = previous
                }
                waiting = true
            }
        }
        var shared = records.shared
        let used = Set(shared.tabs.compactMap(\.folderID))
        shared.folders.removeAll { !used.contains($0.id) }
        return shared
    }

    /// `local` with the records it's missing put back from the cloud's last known copy, for a state
    /// that was just loaded: nothing saw them being removed, so they weren't.
    public func restoringMissing(in local: BrowserState.Shared) -> BrowserState.Shared {
        var ledger = self
        return ledger.receive(saves: [:], local: local)
    }

    /// The cloud was emptied (its data deleted from iCloud settings, or never there): nothing is known
    /// of it any more, so everything here is new to it.
    public mutating func forgetCloud() {
        self = SyncLedger()
    }
}
