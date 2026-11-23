import CryptoKit
import Foundation

/// Files fetched to share a page that is a file, kept so sharing it again (Save to Files, then
/// AirDrop; back from another app; after a relaunch) doesn't fetch 183 MB again. A copy is used
/// again only for the same address and edition (`PageFile.version`) and size; a file whose server
/// gives no edition is used again only until the app quits, since it may have changed since.
///
/// Each file is `<directory>/<key>/<filename>`. A fetch writes into `<key>.part/` and is moved into
/// place only once it's whole, so a fetch the app didn't live to finish is never handed out.
public struct SharedFileCache: Sendable {
    public let directory: URL
    /// Mixed into the key of a file with no edition: a new one each launch.
    private let launch: String
    /// Copies are kept this long since last shared, and while together they come to no more than
    /// `budget` (the newest is kept whatever its size).
    public let maxAge: TimeInterval
    public let budget: Int64

    public init(directory: URL, launch: String = UUID().uuidString, maxAge: TimeInterval = 7 * 24 * 3600,
                budget: Int64 = 500_000_000) {
        self.directory = directory
        self.launch = launch
        self.maxAge = maxAge
        self.budget = budget
    }

    public func key(for file: PageFile) -> String {
        let edition = file.version ?? "launch:" + launch
        let identity = [file.url.absoluteString, edition, file.expectedLength.map(String.init) ?? "", file.filename]
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        // "s": good for this launch only, removed at the next.
        return (file.version == nil ? "s-" : "v-") + hash
    }

    /// The copy of `file` an earlier share fetched, if there's one; marked as just used.
    public func cached(_ file: PageFile) -> URL? {
        let folder = directory.appending(path: key(for: file), directoryHint: .isDirectory)
        let url = folder.appending(path: file.filename)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.path(percentEncoded: false))
        return url
    }

    /// Where a fetch of `file` writes, emptied first.
    public func partialFile(for file: PageFile) throws -> URL {
        let folder = directory.appending(path: key(for: file) + ".part", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: file.filename)
    }

    /// Moves a finished fetch into place and returns where it now is. Older copies go if they're
    /// past their age or the cache is over budget.
    public func keep(_ partial: URL, for file: PageFile) throws -> URL {
        let folder = directory.appending(path: key(for: file), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: partial.deletingLastPathComponent(), to: folder)
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.path(percentEncoded: false))
        prune()
        return folder.appending(path: file.filename)
    }

    /// Removes a fetch that stopped.
    public func discard(_ partial: URL) {
        try? FileManager.default.removeItem(at: partial.deletingLastPathComponent())
    }

    /// At launch: nothing is fetching yet, so unfinished fetches go, as do copies of files with no
    /// edition (they were good for the last launch only), then anything past its age or budget.
    public func pruneAtLaunch() {
        for folder in folders() where folder.lastPathComponent.hasSuffix(".part") || folder.lastPathComponent.hasPrefix("s-") {
            try? FileManager.default.removeItem(at: folder)
        }
        prune()
    }

    /// Copies older than `maxAge` go, then the least recently shared until the rest fit `budget`;
    /// the most recent stays whatever its size, as does any shared in the last `inUse` (a share sheet
    /// may still be sending it). Fetches under way (`.part`) aren't touched.
    public func prune(now: Date = .now, inUse: TimeInterval = 600) {
        let kept = folders()
            .filter { !$0.lastPathComponent.hasSuffix(".part") }
            .map { (url: $0, used: Self.modified($0), size: Self.size(of: $0)) }
            .sorted { $0.used > $1.used }
        var total: Int64 = 0
        for (index, entry) in kept.enumerated() {
            total += entry.size
            let tooOld = now.timeIntervalSince(entry.used) > maxAge
            let recent = now.timeIntervalSince(entry.used) < inUse
            if index > 0, !recent, tooOld || total > budget {
                try? FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }

    private func folders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func size(of folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
