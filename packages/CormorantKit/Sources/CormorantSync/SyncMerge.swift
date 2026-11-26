import Foundation

/// Merging one record changed on two devices. `base` is the copy both started from: the cloud's, as
/// this device last knew it.
enum SyncMerge {
    /// `local` with the other device's changes: field by field, a field changed here keeps this
    /// device's value and any other takes the cloud's. With no `base` (the two devices never agreed on
    /// this record: a first sync), the cloud's record stands, and an order list gains this device's own.
    static func merge(base: SyncRecord?, local: SyncRecord, remote: SyncRecord, id: SyncRecordID) -> SyncRecord {
        if id.kind == .order {
            var merged = remote
            merged.fields[SyncRecord.idsField] = .array(
                list(base: base?.ids ?? [], local: local.ids, remote: remote.ids).map { .string($0.uuidString) })
            return merged
        }
        guard let base else { return remote }
        var merged = remote
        for key in Set(local.fields.keys).union(base.fields.keys) where local.fields[key] != base.fields[key] {
            merged.fields[key] = local.fields[key]
        }
        return merged
    }

    /// Merges two orderings of a list. The other device's order stands unless only this one reordered;
    /// either way what each added is put in after the item it followed there, and what each removed
    /// is gone.
    static func list(base: [UUID], local: [UUID], remote: [UUID]) -> [UUID] {
        let remoteReordered = reordered(base, remote)
        if !remoteReordered, reordered(base, local) {
            return applying(base: base, theirs: remote, onto: local)
        }
        return applying(base: base, theirs: local, onto: remote)
    }

    /// Whether the items both lists hold are in a different order.
    private static func reordered(_ old: [UUID], _ new: [UUID]) -> Bool {
        let inNew = Set(new), inOld = Set(old)
        return old.filter(inNew.contains) != new.filter(inOld.contains)
    }

    /// `mine`, minus what `theirs` removed since `base`, plus what `theirs` added.
    static func applying(base: [UUID], theirs: [UUID], onto mine: [UUID]) -> [UUID] {
        let inBase = Set(base), inTheirs = Set(theirs)
        var seen = Set<UUID>()
        var result = mine.filter { !(inBase.contains($0) && !inTheirs.contains($0)) && seen.insert($0).inserted }
        for (index, id) in theirs.enumerated() where !inBase.contains(id) && !seen.contains(id) {
            seen.insert(id)
            // After the nearest item before it in `theirs` that's in the result; first when there's none.
            let anchor = theirs[..<index].last { result.contains($0) }
            let at = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: at)
        }
        return result
    }
}
