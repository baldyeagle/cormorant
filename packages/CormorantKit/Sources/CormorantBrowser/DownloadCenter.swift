import CormorantCore
import Observation
import OSLog
import UniformTypeIdentifiers
import WebKit

/// Every download, from any tab: what WebKit can't show (or is told to save: `Content-Disposition:
/// attachment`, `<a download>`) and Download Linked File. Files go straight into the app's Documents
/// folder, which the Files app shows as On My iPhone › Cormorant (`UIFileSharingEnabled`,
/// `LSSupportsOpeningDocumentsInPlace`), so the folder is the list: finished downloads are read back
/// from it at launch, and deleting one deletes its file.
///
/// Wallet passes, calendar files and AR models are handed off instead, as Safari does (`Handoff`):
/// written to a temporary folder, never listed, and given to the browser to show the system's viewer
/// for. If that can't take them, the browser keeps them as ordinary downloads (`keep(_:)`).
@MainActor
@Observable
public final class DownloadCenter {
    /// A file that opens in a system viewer rather than landing in Downloads.
    public typealias Handoff = DownloadHandoff

    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case downloading
            case finished
            case failed(String)
        }

        public let id: UUID
        public var filename: String
        /// Where the file is: in `directory` once finished; while it downloads, a hidden folder of its
        /// own there (`.incoming/<id>/`), so a half-written file never shows as a download, in the
        /// list or in Files. Until WebKit has asked where to write it (`hasFile` false), only where it
        /// would be.
        public var fileURL: URL
        /// The file at `fileURL` is this download's.
        var hasFile: Bool
        public var sourceURL: URL?
        public var status: Status
        public var receivedBytes: Int64
        /// -1 while the size isn't known.
        public var expectedBytes: Int64
        let startedAt: Date
        /// Set once WebKit says what it is, for a file handed off rather than listed.
        public var handoff: Handoff?
        /// Whose website data it was downloaded with, to ask for it again with the same.
        public var profileID: UUID? = nil

        /// Try Again asks for the address again, which only means something for a web address.
        public var canRetry: Bool {
            guard case .failed = status else { return false }
            return ["http", "https"].contains(sourceURL?.scheme?.lowercased() ?? "")
        }

        public var fraction: Double? {
            expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
        }
    }

    /// What happened, for the browser's toasts.
    public enum Event {
        case started(Item)
        case finished(Item)
        case failed(Item)
        /// A Wallet pass, calendar file or AR model finished, in a temporary folder: show it, then
        /// `discard(_:)` it, or `keep(_:)` it as a download.
        case handoff(Item)
    }

    /// Newest first, handed-off files among them while they download.
    public private(set) var items: [Item] = []
    /// What the Downloads list shows: everything but files on their way to a system sheet.
    public var listed: [Item] { items.filter { $0.handoff == nil } }
    let directory: URL
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// A web view on a profile's website data (nil: the default profile's) to ask for a download
    /// again with; nil if the profile is gone.
    @ObservationIgnored var retryWebView: ((UUID?) -> WKWebView?)?

    @ObservationIgnored private var active: [UUID: WKDownload] = [:]
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    /// The web views retries were started from, kept until their download ends.
    @ObservationIgnored private var retryWebViews: [UUID: WKWebView] = [:]

    /// The Files app's view of `directory`: `shareddocuments://` opens it there.
    public var filesAppURL: URL? { URL(string: "shareddocuments://" + directory.path(percentEncoded: true)) }

    public var hasActiveDownloads: Bool { listed.contains { $0.status == .downloading } }

    private static let handoffDirectory = URL.temporaryDirectory.appending(path: "Handoffs")
    /// Downloads in progress, hidden from the list and from Files until they finish.
    private var incomingDirectory: URL { directory.appending(path: ".incoming", directoryHint: .isDirectory) }

    public init(directory: URL = URL.documentsDirectory) {
        self.directory = directory
        delegate.center = self
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Left by downloads the app was killed during: they won't finish now.
        try? FileManager.default.removeItem(at: incomingDirectory)
        reload()
    }

    /// Reads the folder back: files someone added or removed in the Files app show up (or go) here.
    /// Downloads in progress and failed ones stay as they are.
    public func reload() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let tracked = Set(items.filter { $0.status != .finished && $0.hasFile }.map(\.fileURL.standardizedFileURL))
        let known = Dictionary(items.filter { $0.status == .finished }.map { ($0.fileURL.standardizedFileURL, $0) },
                               uniquingKeysWith: { first, _ in first })
        var finished: [Item] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  !tracked.contains(file.standardizedFileURL) else { continue }
            let size = Int64(values.fileSize ?? 0)
            var item = known[file.standardizedFileURL] ?? Item(
                id: UUID(), filename: file.lastPathComponent, fileURL: file, hasFile: true, sourceURL: nil, status: .finished,
                receivedBytes: size, expectedBytes: size, startedAt: values.creationDate ?? .distantPast)
            item.status = .finished
            item.receivedBytes = size
            item.expectedBytes = size
            finished.append(item)
        }
        items = (items.filter { $0.status != .finished } + finished).sorted { $0.startedAt > $1.startedAt }
    }

    /// Takes over a download WebKit started (from a page's navigation or `startDownload`).
    @discardableResult
    public func track(_ download: WKDownload) -> UUID {
        download.delegate = delegate
        let id = UUID()
        active[id] = download
        let source = download.originalRequest?.url
        let placeholder = source.map { DownloadNaming.filename(suggested: nil, url: $0, mimeType: nil) } ?? "Download"
        let profileID = download.webView.map { TabSession.profileID(of: $0.configuration.websiteDataStore) }
        let item = Item(id: id, filename: placeholder, fileURL: incomingDirectory.appending(path: "\(id.uuidString)/\(placeholder)"),
                        hasFile: false, sourceURL: source, status: .downloading, receivedBytes: 0, expectedBytes: -1,
                        startedAt: .now, profileID: profileID)
        items.insert(item, at: 0)
        startWatchingProgress()
        return id
    }

    /// Stops it, keeping it on the list to try again. No toast: the user asked for it.
    public func cancel(_ id: UUID) {
        // Off the active list first, so WebKit's own failure callback for it is ignored.
        guard let download = active.removeValue(forKey: id) else { return }
        update(id) { $0.status = .failed("Cancelled") }
        let file = ownFile(id)
        Task {
            _ = await download.cancel()
            if let file { removePartial(file) }
            update(id) { $0.hasFile = false }
            retryWebViews[id] = nil
        }
    }

    /// Starts a failed download again from the start, as a GET of its address (a download a form
    /// posted for can't be asked for again this way). Not resumed: its partial file is gone, so it
    /// never shows in Files as if it were whole.
    public func retry(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), case .failed = item.status,
              let url = item.sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let webView = retryWebView?(item.profileID) else { return }
        remove(id, deletingFile: false)
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            retryWebViews[track(download)] = webView
        }
    }

    /// Takes the download off the list and deletes its file (stopping it first if it's still going).
    public func delete(_ id: UUID) {
        guard let download = active.removeValue(forKey: id) else { return remove(id, deletingFile: true) }
        let file = ownFile(id)
        remove(id, deletingFile: false)
        // WebKit may still be writing it until the cancel lands.
        Task {
            _ = await download.cancel()
            if let file { removePartial(file) }
            retryWebViews[id] = nil
        }
    }

    private func remove(_ id: UUID, deletingFile: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        active[id] = nil
        if deletingFile, item.hasFile { try? FileManager.default.removeItem(at: item.fileURL) }
    }

    /// A download's unfinished file, with the folder of its own it was being written in.
    private func removePartial(_ file: URL) {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        let parent = folder.deletingLastPathComponent().standardizedFileURL
        if parent == incomingDirectory.standardizedFileURL || parent == Self.handoffDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: folder)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The file this download wrote, if it got as far as one.
    private func ownFile(_ id: UUID) -> URL? {
        items.first { $0.id == id && $0.hasFile }?.fileURL
    }

    // MARK: From the delegate

    fileprivate func destination(for download: WKDownload, response: URLResponse, suggestedFilename: String) -> URL? {
        guard let id = id(of: download) else { return nil }
        let name = DownloadNaming.filename(suggested: suggestedFilename, url: response.url, mimeType: response.mimeType)
        // Names other downloads have taken but whose files may not exist yet count as taken too.
        let reserved = Set(items.filter { $0.id != id && $0.status == .downloading }.map(\.filename))
        let unique = DownloadNaming.unique(name) { candidate in
            reserved.contains(candidate) || FileManager.default.fileExists(atPath: directory.appending(path: candidate).path)
        }
        let handoff = Handoff(mimeType: response.mimeType, filename: unique)
        // A folder of its own, so nothing else (a cancelled download's cleanup) touches the file. A
        // listed download moves into `directory` once it's whole (`finish`).
        let folder = (handoff == nil ? incomingDirectory : Self.handoffDirectory).appending(path: id.uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: handoff == nil ? unique : name)
        update(id) {
            $0.filename = handoff == nil ? unique : name
            $0.fileURL = file
            $0.hasFile = true
            $0.sourceURL = response.url ?? $0.sourceURL
            $0.expectedBytes = response.expectedContentLength
            $0.handoff = handoff
        }
        // A pass or invite is small and opens in a moment: no "Downloading" for it. A model can take a
        // while, and nothing else shows it's coming.
        if handoff == nil || handoff == .arModel, let item = items.first(where: { $0.id == id }) { onEvent?(.started(item)) }
        Logger.app.notice("Download started (\(response.mimeType ?? "?", privacy: .public))")
        return file
    }

    fileprivate func didFinish(_ download: WKDownload) {
        guard let id = id(of: download) else { return }
        finish(id, failure: nil)
    }

    fileprivate func didFail(_ download: WKDownload, error: any Error) {
        guard let id = id(of: download) else { return }
        let error = error as NSError
        let message = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
            ? "Cancelled" : error.localizedDescription
        finish(id, failure: message)
    }

    private func finish(_ id: UUID, failure: String?) {
        guard let download = active.removeValue(forKey: id) else { return }
        retryWebViews[id] = nil
        var failure = failure
        if failure == nil, let item = items.first(where: { $0.id == id }), item.handoff == nil, item.hasFile {
            do {
                try moveIn(id)
            } catch {
                Logger.app.error("Couldn't move a finished download in: \(error.localizedDescription, privacy: .public)")
                failure = error.localizedDescription
            }
        }
        update(id) { item in
            item.receivedBytes = max(item.receivedBytes, download.progress.completedUnitCount)
            if let failure {
                item.status = .failed(failure)
            } else {
                item.status = .finished
                // The size on disk, which the response may not have said.
                let size = (try? item.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
                if let size { item.receivedBytes = Int64(size) }
                item.expectedBytes = item.receivedBytes
            }
        }
        if failure != nil, let file = ownFile(id) {
            // A partial file isn't a download.
            removePartial(file)
            // A failed pass or invite is listed, to try again.
            update(id) { $0.hasFile = false; $0.handoff = nil }
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        if failure == nil, item.handoff != nil {
            items.removeAll { $0.id == id }
            onEvent?(.handoff(item))
            return
        }
        onEvent?(failure == nil ? .finished(item) : .failed(item))
    }

    /// A finished download, from its folder in `.incoming` into `directory`, under its name or, if a
    /// file of that name turned up meanwhile (from Files), the next free one.
    private func moveIn(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let reserved = Set(items.filter { $0.id != id && $0.status == .downloading }.map(\.filename))
        let name = DownloadNaming.unique(item.filename) { candidate in
            reserved.contains(candidate) || FileManager.default.fileExists(atPath: directory.appending(path: candidate).path)
        }
        let file = directory.appending(path: name)
        try FileManager.default.moveItem(at: item.fileURL, to: file)
        removePartial(item.fileURL)
        update(id) {
            $0.filename = name
            $0.fileURL = file
        }
    }

    /// A handed-off file the system sheet couldn't take, moved into Downloads like any other. Returns
    /// it as listed there.
    @discardableResult
    public func keep(_ item: Item) -> Item? {
        let name = DownloadNaming.unique(item.filename) { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
        let file = directory.appending(path: name)
        do {
            try FileManager.default.moveItem(at: item.fileURL, to: file)
        } catch {
            Logger.app.error("Couldn't keep a handed-off download: \(error.localizedDescription, privacy: .public)")
            discard(item)
            return nil
        }
        discard(item)
        reload()
        return items.first { $0.fileURL.standardizedFileURL == file.standardizedFileURL }
    }

    /// A handed-off file, done with.
    public func discard(_ item: Item) { discardHandoff(at: item.fileURL) }

    /// The handed-off file at `file`, done with.
    func discardHandoff(at file: URL) {
        // Its own folder in the handoff folder, never anything else (Downloads itself).
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().standardizedFileURL == Self.handoffDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func id(of download: WKDownload) -> UUID? {
        active.first { $0.value === download }?.key
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Progress is read a few times a second while anything downloads, rather than observed: KVO on
    /// `Progress` fires for every chunk, off the main actor.
    private func startWatchingProgress() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while let self, !self.active.isEmpty, !Task.isCancelled {
                for (id, download) in self.active {
                    let progress = download.progress
                    self.update(id) {
                        $0.receivedBytes = progress.completedUnitCount
                        if progress.totalUnitCount > 0 { $0.expectedBytes = progress.totalUnitCount }
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.progressTask = nil
        }
    }

    /// WebKit's delegate (it must be an `NSObject`); hands everything to the center.
    private final class Delegate: NSObject, WKDownloadDelegate {
        weak var center: DownloadCenter?

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            center?.destination(for: download, response: response, suggestedFilename: suggestedFilename)
        }

        func downloadDidFinish(_ download: WKDownload) {
            center?.didFinish(download)
        }

        func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
            center?.didFail(download, error: error)
        }
    }
}

extension DownloadCenter.Item {
    /// An SF Symbol for the file's kind.
    public var symbolName: String {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return "doc.plaintext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        return "doc"
    }
}
