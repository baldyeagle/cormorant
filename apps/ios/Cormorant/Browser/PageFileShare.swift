import CormorantCore
import OSLog
import UIKit
import WebKit

/// Share on a page that is a file (a PDF, an image): the share sheet gets the file itself, so Save to
/// Files, Markup, Print and AirDrop get the PDF rather than its address, as in Safari and Arc.
///
/// WebKit can't hand over the copy the tab shows (a web archive of a PDF page holds only the viewer's
/// wrapper), so the file is fetched again, through the tab's web view so its cookies go with it,
/// under a toast that counts it up. The sheet opens once it's all here, if the toast is still up;
/// swiped away, the fetch carries on and a toast says when it's ready. Only Cancel stops it. What's
/// fetched is kept (`SharedFileCache`), so sharing the same file again opens the sheet at once.
enum PageFileShare {
    /// Replaced by tests with a throwaway one.
    static var cache = SharedFileCache(directory: URL.cachesDirectory.appending(path: "Shared Files", directoryHint: .isDirectory))

    /// Fetches under way, by cache key: sharing a file again while it comes follows the same fetch.
    private static var fetches: [String: PageFileFetch] = [:]

    enum Outcome: Equatable {
        /// Already here: the sheet is opening (over the caret sheet, which can stay).
        case sharing
        /// Coming, under a toast: the caret sheet should close.
        case fetching
    }

    /// `present` shows the share sheet for these items: the file, or the link when it couldn't be had.
    @discardableResult
    static func share(_ file: PageFile, from session: TabSession, store: BrowserStore,
                      present: @escaping @MainActor ([Any]) -> Void = presentSheet) -> Outcome {
        if let url = cache.cached(file) {
            present([url])
            return .sharing
        }
        let key = cache.key(for: file)
        let fetch = fetches[key] ?? {
            let fetch = PageFileFetch(file: file, webView: session.webView, cache: cache)
            fetches[key] = fetch
            fetch.start()
            return fetch
        }()
        let toast = Toast(icon: .symbol("square.and.arrow.up"), message: "Getting \(file.filename)",
                          actions: [Toast.Action("Cancel") { cancel(fetch, key: key) }], tabID: session.tabID,
                          transfer: Toast.Transfer { fetch.progress }, staysUp: true)
        fetch.toastID = toast.id
        // The latest share's: its sheet is the one that opens.
        fetch.onFinish = { [weak store] result in
            guard let store else { return }
            finished(fetch, key: key, result: result, store: store, present: present)
        }
        store.showToast(toast)
        return .fetching
    }

    private static func cancel(_ fetch: PageFileFetch, key: String) {
        fetch.cancel()
        if fetches[key] === fetch { fetches[key] = nil }
    }

    private static func finished(_ fetch: PageFileFetch, key: String, result: Result<URL, any Error>,
                                 store: BrowserStore, present: @escaping @MainActor ([Any]) -> Void) {
        if fetches[key] === fetch { fetches[key] = nil }
        let file = fetch.file
        // Still waiting on it: the toast for this fetch is the one up.
        let watching = fetch.toastID != nil && store.toast?.id == fetch.toastID
        if watching { store.dismissToast(fetch.toastID) }
        if case .success(let url) = result, watching { return present([url]) }
        if case .failure(let error) = result {
            Logger.app.error("Share couldn't get the page's file: \(error.localizedDescription, privacy: .public)")
        }
        // Swiped away: say how it ended, once the app's in front (a toast's seconds run out in the
        // background too), and not over another file's progress, whose sheet is still to open.
        whenActive {
            if let shown = store.toast, shown.staysUp, shown.transfer != nil { return }
            switch result {
            case .success:
                // From the cache when tapped: the copy may have been replaced or pruned since.
                store.showToast(Toast(icon: .symbol("checkmark.circle"), message: "\(file.filename) is ready",
                                      actions: [Toast.Action("Share") { present([cache.cached(file).map { $0 as Any } ?? file.url]) }]))
            case .failure:
                // Not about the tab, which may have closed: the link is the file's.
                store.showToast(Toast(icon: .symbol("exclamationmark.circle"), message: "Couldn't get \(file.filename)",
                                      actions: [Toast.Action("Share Link") { present([file.url]) }]))
            }
        }
    }

    /// Now, or when the app's next in front.
    private static func whenActive(_ body: @escaping @MainActor () -> Void) {
        guard UIApplication.shared.applicationState != .active else { return body() }
        final class Token { var observer: (any NSObjectProtocol)? }
        let token = Token()
        token.observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = token.observer { NotificationCenter.default.removeObserver(observer) }
                token.observer = nil
                body()
            }
        }
    }

    static func presentSheet(_ items: [Any]) {
        // The caret sheet Share was tapped in may still be closing (a file the disk cache had comes
        // in less time than that takes): nothing can be presented until it's gone.
        if let leaving = closingController(), let coordinator = leaving.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in presentSheet(items) }
            return
        }
        guard let presenter = HandoffPresenter.topViewController() else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY, width: 0, height: 0)
        }
        presenter.present(controller, animated: true)
    }

    private static func closingController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var controller = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = controller?.presentedViewController {
            if presented.isBeingDismissed { return presented }
            controller = presented
        }
        return nil
    }

    #if DEBUG
    /// Tests: stops every fetch a test left going.
    static func cancelAll() {
        for fetch in fetches.values { fetch.cancel() }
        fetches = [:]
    }
    #endif
}

/// One fetch of a page's file for Share, into the share cache. Keeps going in the background for
/// as long as iOS gives it; one cut off there (or by a blip in the network) picks up where it got to
/// once the app is back, a few times at most, before it says it failed.
final class PageFileFetch: NSObject, WKDownloadDelegate {
    let file: PageFile
    var toastID: UUID?
    /// Called once, when it's whole or has failed; not after `cancel()`.
    var onFinish: (@MainActor (Result<URL, any Error>) -> Void)?

    private weak var webView: WKWebView?
    private let cache: SharedFileCache
    private var download: WKDownload?
    private var partial: URL?
    private var resumes = 0
    /// The edition the server sent: kept under its own key, so a page showing an older one fetches again.
    private var edition: PageFile?
    /// The size the server gave, when it's the file's (not sent compressed): a file that comes
    /// shorter was cut off.
    private var expectedLength: Int64?
    /// The last count, shown while a cut-off fetch waits to resume.
    private var lastProgress: (received: Int64, expected: Int64?) = (0, nil)
    private var done = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activeObserver: (any NSObjectProtocol)?

    init(file: PageFile, webView: WKWebView, cache: SharedFileCache) {
        self.file = file
        self.webView = webView
        self.cache = cache
    }

    isolated deinit {
        download?.cancel()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    }

    /// Bytes so far, and of how many when that's known.
    var progress: (received: Int64, expected: Int64?) {
        guard let progress = download?.progress else {
            return (lastProgress.received, lastProgress.expected ?? file.expectedLength)
        }
        let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : file.expectedLength
        lastProgress = (max(0, progress.completedUnitCount), total)
        return lastProgress
    }

    func start() {
        guard let webView else { return finish(.failure(URLError(.cancelled))) }
        holdBackgroundTime()
        webView.startDownload(using: URLRequest(url: file.url)) { [self] in adopt($0) }
    }

    /// Stops it and throws away what came; `onFinish` isn't called.
    func cancel() {
        onFinish = nil
        finish(.failure(CocoaError(.userCancelled)))
    }

    private func adopt(_ download: WKDownload) {
        guard !done else { return download.cancel() }
        self.download = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard download === self.download else { return nil }
        // The same file, or nothing: not an error page, nor a sign-in page answering in its place.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let type = response.mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard status < 400, type == file.mimeType else {
            finish(.failure(URLError(.badServerResponse)))
            return nil
        }
        let http = response as? HTTPURLResponse
        let served = PageFile(url: file.url, mimeType: file.mimeType, suggestedFilename: file.filename,
                              version: PageFile.version(etag: http?.value(forHTTPHeaderField: "ETag"),
                                                        lastModified: http?.value(forHTTPHeaderField: "Last-Modified")),
                              expectedLength: response.expectedContentLength) ?? file
        // The page's own edition (where the page didn't say its size, this says nothing new) is kept
        // as the page's, for Share to find; another is kept as itself.
        let same = served.version == file.version && (file.expectedLength == nil || file.expectedLength == served.expectedLength)
        let edition = same ? file : served
        self.edition = edition
        // Sent compressed, the size given is the compressed one, not the file's.
        let encoding = http?.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        let identity = encoding == nil || encoding == "identity"
        expectedLength = identity && response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        do {
            let url = try cache.partialFile(for: edition)
            partial = url
            return url
        } catch {
            finish(.failure(error))
            return nil
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === self.download else { return }
        self.download = nil
        guard let partial, let edition else { return finish(.failure(URLError(.cannotCreateFile))) }
        // Cut short with the connection closed: not the file.
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        if let expected = expectedLength, size != expected {
            return finish(.failure(URLError(.networkConnectionLost)))
        }
        do {
            let url = try cache.keep(partial, for: edition)
            self.partial = nil
            finish(.success(url))
        } catch {
            finish(.failure(error))
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard download === self.download else { return }
        self.download = nil
        guard let resumeData, partial != nil, resumes < 3 else { return finish(.failure(error)) }
        resumes += 1
        if UIApplication.shared.applicationState == .active {
            resume(from: resumeData)
        } else {
            // Cut off in the background: carry on from where it got to once the app is back.
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(from: resumeData) }
            }
        }
    }

    private func resume(from resumeData: Data) {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        guard !done else { return }
        guard let webView else { return finish(.failure(URLError(.networkConnectionLost))) }
        holdBackgroundTime()
        webView.resumeDownload(fromResumeData: resumeData) { [self] in adopt($0) }
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard !done else { return }
        done = true
        download?.cancel()
        download = nil
        if let partial { cache.discard(partial) }
        partial = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        releaseBackgroundTime()
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?(result)
    }

    /// Asks iOS for time to finish if the app goes to the background meanwhile.
    private func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Share file") { [weak self] in
            MainActor.assumeIsolated { self?.releaseBackgroundTime() }
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
