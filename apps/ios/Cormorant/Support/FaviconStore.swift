import CormorantCore
import Foundation
import ImageIO
import Observation
import OSLog
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Site icons for the tab switcher and search rows, keyed by `FaviconSelector.hostKey(for:)`.
/// Fetched after a page finishes loading and cached small on disk; all IO and decoding is off the
/// main actor, and every failure just leaves the site without an icon.
@MainActor
@Observable
final class FaviconStore {
    /// A cached icon older than this is fetched again on the next visit, so a site's new icon shows up.
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// After a fetch where nothing usable came back, the host isn't tried again for this long.
    static let failureRetryInterval: TimeInterval = 60 * 60
    /// Declared icons tried per fetch, before `/favicon.ico`.
    static let maxDeclaredAttempts = 4
    nonisolated static let maxPixelSize = 96
    nonisolated static let maxResponseBytes = 512 * 1024
    /// Rejects absurd dimensions before decoding: a small PNG can still expand to gigabytes.
    nonisolated static let maxSourcePixels = 4096
    /// An ICO holds a handful of sizes; anything with more images isn't worth parsing.
    nonisolated static let maxImagesPerFile = 16
    /// A page whose main thread is stuck mustn't hold its host's fetch open.
    static let scriptTimeout: Duration = .seconds(3)

    /// One observable slot per host, so an icon arriving re-renders only the views showing that host.
    /// Not evicted: at most 96 px each, one per site visited this launch.
    @ObservationIgnored private var slots: [String: Slot] = [:]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession
    /// Hosts whose disk copy has been looked for (or is being).
    @ObservationIgnored private var diskChecked: Set<String> = []
    /// Earliest time each host may be fetched again; unset until the host's disk copy (if any) is checked.
    @ObservationIgnored private var nextFetch: [String: Date] = [:]
    @ObservationIgnored private var fetching: Set<String> = []

    nonisolated private static let log = Logger(subsystem: "dev.baldyeagle.cormorant", category: "favicons")
    /// Reads every `<link>` whose rel mentions an icon. Runs in the client world, so the page's own
    /// scripts (a patched `Array.from`, a hostile `querySelectorAll`) can't interfere or see it.
    private static let linksScript = """
        const links = Array.from(document.querySelectorAll('link[rel][href]'))
            .filter(l => l.rel.toLowerCase().includes('icon'))
            .slice(0, 32)
            .map(l => ({ href: l.href, rel: l.rel, sizes: l.getAttribute('sizes'), type: l.getAttribute('type') }));
        return { links, userAgent: navigator.userAgent };
        """

    init(directory: URL = .cachesDirectory.appending(path: "Favicons", directoryHint: .isDirectory)) {
        self.directory = directory
        // Ephemeral with no cookies or cache: an icon fetch must not carry or set the user's session.
        // Only where that met a sign-in does the page itself fetch its own icon (`downloadThroughPage`).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    /// The icon for `url`'s site, if one is known. Read from a view body: the first ask for a host
    /// starts a disk lookup, and the view re-renders when it (or a later fetch) lands.
    func icon(for url: URL?) -> UIImage? {
        guard let url, let key = FaviconSelector.hostKey(for: url) else { return nil }
        if diskChecked.insert(key).inserted {
            Task { await loadFromDisk(key) }
        }
        return slot(for: key).image
    }

    /// Whether `url`'s site's icon is being fetched now (for tests to wait on).
    func isFetching(_ url: URL) -> Bool {
        FaviconSelector.hostKey(for: url).map(fetching.contains) ?? false
    }

    /// Call when a main-frame load finishes. Fetches the site's icon unless a recent one is cached.
    func pageDidLoad(in webView: WKWebView) {
        guard let pageURL = webView.url, ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
              let key = FaviconSelector.hostKey(for: pageURL), !fetching.contains(key)
        else { return }
        if let next = nextFetch[key], next > .now { return }
        fetching.insert(key)
        // Weak: a closed tab's web view (and its page, audio and all) must not outlive the tab while
        // icons download.
        Task { [weak webView] in
            defer { fetching.remove(key) }
            if nextFetch[key] == nil, let modified = await loadFromDisk(key),
               modified.addingTimeInterval(Self.refreshInterval) > .now {
                return
            }
            // Scoped so the web view is released before the downloads start.
            let page: PageInfo? = if let webView { await pageInfo(in: webView, key: key) } else { nil }
            guard let page else { return } // Script failed or the tab went away; the next load retries.
            // A page can declare dozens of dead links; at 10 s each, cap the attempts but keep the fallback.
            let ranked = FaviconSelector.best(from: page.candidates, pageURL: pageURL)
            let urls = ranked.dropLast().prefix(Self.maxDeclaredAttempts) + ranked.suffix(1)
            let request = Request(userAgent: page.userAgent, pageHost: pageURL.host()?.lowercased())
            let result = await Self.download(Array(urls), session: session, request: request, to: file(for: key))
            if let image = result.image {
                store(image, for: key)
                nextFetch[key] = .now.addingTimeInterval(Self.refreshInterval)
            } else if !result.signInURLs.isEmpty {
                // Behind a sign-in (Cloudflare Access, say), where a request without the page's cookies
                // gets only the sign-in page: the page fetches those itself. Weak: a tab closed meanwhile
                // doesn't wait on it. (Cached by host like any icon, so a Space on another profile shows
                // it too.)
                if let image = await downloadThroughPage(result.signInURLs, in: { [weak webView] in webView }, key: key) {
                    store(image, for: key)
                    nextFetch[key] = .now.addingTimeInterval(Self.refreshInterval)
                } else {
                    // Likely signed out: the next load, signed in by then, tries again.
                    nextFetch.removeValue(forKey: key)
                }
            } else {
                Self.log.debug("No usable icon for \(key, privacy: .private)")
                nextFetch[key] = .now.addingTimeInterval(Self.failureRetryInterval)
            }
        }
    }

    /// Drops every cached icon (memory and disk) except those for `urls`' sites, so the cache stops
    /// recording where the user has been.
    func forgetSites(except urls: [URL]) {
        let keep = Set(urls.compactMap(FaviconSelector.hostKey(for:)))
        for key in slots.keys where !keep.contains(key) { slots[key]?.image = nil }
        diskChecked = diskChecked.intersection(keep)
        nextFetch = nextFetch.filter { keep.contains($0.key) }
        let keepFiles = Set(keep.map { file(for: $0).lastPathComponent })
        let directory = directory
        Task { await Self.deleteFiles(in: directory, except: keepFiles) }
    }

    // MARK: Private

    /// Loads the host's disk copy into memory (unless a fresher icon got there first) and returns
    /// its modification date, or nil when there's no usable copy.
    @discardableResult
    private func loadFromDisk(_ key: String) async -> Date? {
        diskChecked.insert(key)
        guard let cached = await Self.readCached(file(for: key)) else { return nil }
        if slot(for: key).image == nil { store(cached.image, for: key) }
        if nextFetch[key] == nil { nextFetch[key] = cached.modified.addingTimeInterval(Self.refreshInterval) }
        return cached.modified
    }

    private func store(_ image: UIImage, for key: String) {
        slot(for: key).image = image
    }

    private func slot(for key: String) -> Slot {
        if let slot = slots[key] { return slot }
        let slot = Slot()
        slots[key] = slot
        return slot
    }

    private struct PageInfo: Sendable {
        let candidates: [FaviconCandidate]
        let userAgent: String?

        /// From `linksScript`'s result; nil if it isn't the expected shape.
        init?(_ value: Any?) {
            guard let result = value as? [String: Any] else { return nil }
            let links = result["links"] as? [[String: Any]] ?? []
            candidates = links.compactMap { link in
                guard let href = link["href"] as? String, let url = URL(string: href),
                      let rel = link["rel"] as? String else { return nil }
                return FaviconCandidate(url: url, rel: rel, sizes: link["sizes"] as? String, type: link["type"] as? String)
            }
            userAgent = result["userAgent"] as? String
        }
    }

    /// The page's icon links and user agent, or nil if the script fails, takes longer than
    /// `scriptTimeout` (WebKit has no timeout of its own for a page stuck in a loop), or the page
    /// has moved to another site by the time it answers.
    private func pageInfo(in webView: WKWebView, key: String) async -> PageInfo? {
        let page: PageInfo? = await withCheckedContinuation { continuation in
            let reply = Reply<PageInfo>(continuation)
            webView.callAsyncJavaScript(Self.linksScript, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): reply.resume(PageInfo(value))
                case .failure(let error):
                    Self.log.debug("Reading icon links failed: \(error.localizedDescription, privacy: .public)")
                    reply.resume(nil)
                }
            }
            Task {
                try? await Task.sleep(for: Self.scriptTimeout)
                reply.resume(nil)
            }
        }
        return webView.url.flatMap(FaviconSelector.hostKey(for:)) == key ? page : nil
    }

    /// Resumes its continuation once, with whichever of the script and the timeout finishes first.
    private final class Reply<Value: Sendable> {
        private var continuation: CheckedContinuation<Value?, Never>?

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Value?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Fetches the icon in the page itself, so with its sign-in, where a fetch without it met one
    /// (`download`'s `signInURLs`): only `urls` on the page's own origin, which the page could fetch
    /// anyway, and only an answer from that origin (a redirect to a sign-in page elsewhere isn't
    /// one). The bytes are decoded here, as `download`'s are. Nil if none of them gives an icon, the
    /// tab has gone, or the page has moved to another site meanwhile. The web view is looked up again
    /// for each URL, so a closed tab's is held at most for one fetch.
    private func downloadThroughPage(_ urls: [URL], in webView: () -> WKWebView?, key: String) async -> UIImage? {
        for url in urls {
            guard let webView = webView(), let pageURL = webView.url,
                  FaviconSelector.hostKey(for: pageURL) == key else { return nil }
            guard FaviconSelector.sameOrigin(url, pageURL) else { continue }
            let encoded: String? = await withCheckedContinuation { continuation in
                let reply = Reply<String>(continuation)
                webView.callAsyncJavaScript(Self.pageFetchScript,
                                            arguments: ["href": url.absoluteString, "max": Self.maxResponseBytes],
                                            in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value): reply.resume(value as? String)
                    case .failure(let error):
                        Self.log.debug("Fetching an icon in the page failed: \(error.localizedDescription, privacy: .public)")
                        reply.resume(nil)
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    reply.resume(nil)
                }
            }
            guard let encoded, let image = await Self.keep(base64: encoded, as: file(for: key)) else { continue }
            return image
        }
        return nil
    }

    /// `href` fetched by the page, as base64, or null for an error, a redirect off the page's origin, or
    /// more than `max` bytes (read as it streams, and stopped there). Given up after 8 s, inside the
    /// caller's 10. In the client world, like `linksScript`, out of the page's scripts' reach.
    private static let pageFetchScript = """
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 8000);
        try {
            const response = await fetch(href, { credentials: 'same-origin', cache: 'no-cache', signal: controller.signal });
            if (!response.ok || !response.body || new URL(response.url).origin !== location.origin
                || Number(response.headers.get('content-length') || 0) > max) {
                controller.abort();
                return null;
            }
            const reader = response.body.getReader();
            const chunks = [];
            let size = 0;
            for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                size += value.length;
                if (size > max) { controller.abort(); return null; }
                chunks.push(value);
            }
            let binary = '';
            for (const chunk of chunks) {
                for (let i = 0; i < chunk.length; i += 0x8000) {
                    binary += String.fromCharCode.apply(null, chunk.subarray(i, i + 0x8000));
                }
            }
            return btoa(binary);
        } catch {
            return null;
        } finally {
            clearTimeout(timer);
        }
        """

    private func file(for key: String) -> URL {
        // Host keys are already lowercase; anything outside a DNS name's characters is escaped.
        let safe = key.addingPercentEncoding(withAllowedCharacters: Self.fileNameAllowed) ?? "_"
        return directory.appending(path: "\(safe).png", directoryHint: .notDirectory)
    }

    private static let fileNameAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")

    private struct CachedIcon: Sendable {
        let image: UIImage
        let modified: Date
    }

    @concurrent
    nonisolated private static func deleteFiles(in directory: URL, except keep: Set<String>) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @concurrent
    nonisolated private static func readCached(_ file: URL) async -> CachedIcon? {
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let image = UIImage(contentsOfFile: file.path)?.preparingForDisplay()
        else { return nil }
        return CachedIcon(image: image, modified: modified)
    }

    /// Tries `urls` in order; the first that downloads and decodes is scaled down, written to `file`
    /// and returned.
    @concurrent
    ///
    /// `signInURLs` are the ones that met a sign-in instead: a 401 or 403, or a redirect to an HTML page.
    nonisolated private static func download(
        _ urls: [URL], session: URLSession, request: Request, to file: URL
    ) async -> (image: UIImage?, signInURLs: [URL]) {
        var signInURLs: [URL] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            let fetched = await fetch(url, session: session, request: request)
            if fetched.metSignIn { signInURLs.append(url) }
            guard let data = fetched.data, let image = await keep(data, as: file) else { continue }
            return (image, [])
        }
        return (nil, signInURLs)
    }

    @concurrent
    nonisolated private static func keep(base64: String, as file: URL) async -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return await keep(data, as: file)
    }

    /// Decodes `data` as an icon (`thumbnail`), writes it to `file` and returns it; nil if it isn't one.
    @concurrent
    nonisolated private static func keep(_ data: Data, as file: URL) async -> UIImage? {
        guard let icon = thumbnail(from: data) else { return nil }
        if let png = pngData(icon) {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
            } catch {
                log.debug("Caching icon failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return UIImage(cgImage: icon)
    }

    /// The body of a 2xx response no larger than `maxResponseBytes`, else nil; `metSignIn` when the
    /// answer was a 401 or 403, or a redirect to an HTML page (a sign-in page, by the look of it).
    nonisolated private static func fetch(_ url: URL, session: URLSession, request: Request) async -> (data: Data?, metSignIn: Bool) {
        var urlRequest = URLRequest(url: url)
        // The page's own user agent, so the fetch doesn't single the browser out.
        if let userAgent = request.userAgent { urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: RedirectGuard(pageHost: request.pageHost))
            guard let http = response as? HTTPURLResponse else { return (nil, false) }
            let metSignIn = http.statusCode == 401 || http.statusCode == 403
                || (http.url != url && http.mimeType?.lowercased() == "text/html")
            guard !metSignIn, (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(maxResponseBytes)
            else { return (nil, metSignIn) }
            var data = Data()
            data.reserveCapacity(http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 16 * 1024)
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxResponseBytes { return (nil, false) }
            }
            return (data, false)
        } catch {
            log.debug("Icon fetch failed: \(error.localizedDescription, privacy: .public)")
            return (nil, false)
        }
    }

    /// Decodes the largest image in `data` (an ICO holds several sizes) and scales it to fit
    /// `maxPixelSize`, keeping its aspect ratio.
    nonisolated private static func thumbnail(from data: Data) -> CGImage? {
        // Decoded here, in the app rather than WebKit's sandboxed web process, so only the plain
        // formats icons come in reach ImageIO, checked by their bytes before it parses anything.
        guard imageSignatures.contains(where: { data.starts(with: $0) }),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type),
              CGImageSourceGetCount(source) <= maxImagesPerFile
        else { return nil }
        var best: (index: Int, width: Int, height: Int)?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { continue }
            if width > best?.width ?? 0 { best = (index, width, height) }
        }
        guard let best, best.width <= maxSourcePixels, best.height <= maxSourcePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best.index, options as CFDictionary),
              image.width >= 8, image.height >= 8 // 1x1 tracking pixels and blank placeholders
        else { return nil }
        return image
    }

    /// PNG, ICO, JPEG and GIF.
    nonisolated private static let imageSignatures: [[UInt8]] = [
        [0x89, 0x50, 0x4E, 0x47], [0x00, 0x00, 0x01, 0x00], [0xFF, 0xD8, 0xFF], [0x47, 0x49, 0x46, 0x38],
    ]
    nonisolated private static let allowedTypes: Set<String> = [
        UTType.png.identifier, UTType.ico.identifier, UTType.jpeg.identifier, UTType.gif.identifier,
    ]

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    @Observable
    fileprivate final class Slot {
        var image: UIImage?
    }

    private struct Request: Sendable {
        let userAgent: String?
        let pageHost: String?
    }

    /// Refuses redirects into the local network (unless the page itself is there) and from https
    /// down to http: a page could otherwise launder either through a public icon URL.
    nonisolated private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let pageHost: String?

        init(pageHost: String?) {
            self.pageHost = pageHost
        }

        // The completion-handler form: the async one crashes the Swift 6.4 compiler in an @objc thunk.
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(allows(request.url, from: task.originalRequest?.url) ? request : nil)
        }

        private func allows(_ url: URL?, from original: URL?) -> Bool {
            guard let url, let host = url.host()?.lowercased() else { return false }
            if host != pageHost, FaviconSelector.isLocal(host: host) { return false }
            return original?.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https"
        }
    }
}
