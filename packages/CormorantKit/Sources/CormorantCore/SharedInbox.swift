import Foundation

/// URLs handed to the app from outside (share extension, URL scheme). The extension appends;
/// the app drains on launch and foreground.
public struct OpenRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let receivedAt: Date

    public init(id: UUID = UUID(), url: URL, receivedAt: Date = .now) {
        self.id = id
        self.url = url
        self.receivedAt = receivedAt
    }
}

/// Append-only JSON file in the app-group container. Safe for one writer and one reader at a time
/// via `NSFileCoordinator`.
public struct SharedInbox: Sendable {
    public let fileURL: URL

    /// Returns nil when the app group is unavailable rather than silently using a per-process directory.
    public init?(appGroup: String = AppGroup.identifier, fileManager: FileManager = .default) {
        guard let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        self.fileURL = base.appending(path: "inbox.json")
    }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func append(_ request: OpenRequest) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinate(.forMerging) { url in
            var requests = try Self.read(at: url)
            requests.append(request)
            try CoreJSON.encoder().encode(requests).write(to: url, options: .atomic)
        }
    }

    /// Returns all pending requests, oldest first, and empties the inbox.
    ///
    /// The read and the delete happen inside one coordinated write so an append from another
    /// process cannot land between them and be lost. A corrupt inbox is deleted and the decode
    /// error rethrown, so one bad write cannot wedge the inbox forever.
    public func drain() throws -> [OpenRequest] {
        try coordinate(.forDeleting) { url in
            let requests: [OpenRequest]
            do {
                requests = try Self.read(at: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Nothing was pending.
            }
            return requests.sorted { $0.receivedAt < $1.receivedAt }
        }
    }

    /// Requests stored at `url`; empty if the file does not exist.
    private static func read(at url: URL) throws -> [OpenRequest] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try CoreJSON.decoder().decode([OpenRequest].self, from: data)
    }

    /// Runs `body` under a coordinated write on `fileURL`, surfacing errors from either the
    /// coordinator or the body.
    private func coordinate<T>(_ options: NSFileCoordinator.WritingOptions,
                               _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL, options: options, error: &coordinationError
        ) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}
