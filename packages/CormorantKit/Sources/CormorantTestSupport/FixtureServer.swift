import Foundation
import Network

/// Serves one fixed HTML page on 127.0.0.1 so the tests need no network: the app's UI tests (the
/// app and the test runner share the simulator's loopback), its in-process tests, and any platform's.
/// Every path gets the same page, except those in `files` (a download's body and headers); `delays`
/// holds back the first request for some, `holds` every request for some until the test calls
/// `release(_:)`. With `signIn`, it stands in for a site behind a sign-in (Cloudflare Access, say):
/// every request but `/login`'s without that cookie is sent to `/login`.
/// Counts requests by path, so a test can tell a page that was loaded again from one that wasn't.
public final class FixtureServer {
    public struct StartFailed: Error {}

    /// A response other than the page: a file, with its own type and any extra headers
    /// (`Content-Disposition`).
    public struct File: Sendable {
        public let contentType: String
        public let body: Data
        public var headers: [String: String]

        public init(contentType: String, body: Data, headers: [String: String] = [:]) {
            self.contentType = contentType
            self.body = body
            self.headers = headers
        }
    }

    public let port: UInt16
    private let listener: NWListener
    private let counts: Counts
    private let held: Held

    /// - Parameter delays: seconds to wait before answering the first request for a path (`/slow`).
    ///   Later ones are answered at once, so a test can hold a link preview's load back for longer than
    ///   a slow simulator takes to pick a menu item, without the tab's own load waiting too.
    /// - Parameter holds: paths whose requests go unanswered until `release(_:)` is called for them.
    /// - Parameter files: paths answered with a file instead of the page.
    /// - Parameter signIn: a cookie (`session=ok`) a request must carry, or be redirected to `/login`.
    public init(html: String, delays: [String: Double] = [:], holds: Set<String> = [], files: [String: File] = [:],
                signIn: String? = nil) throws {
        let page = Self.response(File(contentType: "text/html; charset=utf-8", body: Data(html.utf8)))
        let fileResponses = files.mapValues(Self.response)
        let toLogin = Data("HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "FixtureServer")
        let counts = Counts()
        let held = Held(paths: holds)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            // Answer once the request starts arriving; only its path matters.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let path = data.flatMap(Self.path(of:))
                let nth = path.map { counts.add($0) }
                let signedOut = signIn.map { cookie in
                    path != "/login" && !(data.map { Self.cookies(in: $0).contains(cookie) } ?? false)
                } ?? false
                let response = signedOut ? toLogin : path.flatMap { fileResponses[$0] } ?? page
                let send: @Sendable () -> Void = {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
                if let path, held.hold(send, for: path) {
                    // Sent by `release(_:)`.
                } else if nth == 1, let delay = path.flatMap({ delays[$0] }) {
                    queue.asyncAfter(deadline: .now() + delay, execute: send)
                } else {
                    send()
                }
            }
        }
        let settled = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: settled.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = settled.wait(timeout: .now() + 5)
        guard listener.state == .ready, let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw StartFailed()
        }
        self.listener = listener
        self.port = port
        self.counts = counts
        self.held = held
    }

    /// Answers the requests held for `path` (one of `holds`), and any that come for it from now on.
    public func release(_ path: String) {
        for send in held.release(path) { send() }
    }

    public var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Requests received so far for `path` (`/next`).
    public func requestCount(for path: String) -> Int { counts.count(for: path) }

    /// Every request so far, one per line with seconds since the server started, for failure messages.
    public var requestLog: String { counts.log }

    private static func response(_ file: File) -> Data {
        let lines = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(file.contentType)",
            "Content-Length: \(file.body.count)",
            "Connection: close",
        ] + file.headers.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + file.body
    }

    /// The request's cookies, `name=value` each.
    private static func cookies(in request: Data) -> [String] {
        String(decoding: request, as: UTF8.self).split(separator: "\r\n")
            .filter { $0.lowercased().hasPrefix("cookie:") }
            .flatMap { $0.dropFirst("cookie:".count).split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `GET /next HTTP/1.1` → `/next`.
    private static func path(of request: Data) -> String? {
        guard let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date.now
        private var byPath: [String: Int] = [:]
        private var lines: [String] = []

        /// Counts a request for `path`; returns how many there have been, this one included.
        func add(_ path: String) -> Int {
            lock.withLock {
                byPath[path, default: 0] += 1
                lines.append(String(format: "+%.2fs GET %@", Date.now.timeIntervalSince(start), path))
                return byPath[path, default: 0]
            }
        }

        var log: String { lock.withLock { "requests:\n" + lines.joined(separator: "\n") } }
        func count(for path: String) -> Int { lock.withLock { byPath[path, default: 0] } }
    }

    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String>
        private var waiting: [String: [@Sendable () -> Void]] = [:]

        init(paths: Set<String>) { self.paths = paths }

        /// Keeps `send` for later if `path` is held; false if it isn't, to answer now.
        func hold(_ send: @escaping @Sendable () -> Void, for path: String) -> Bool {
            lock.withLock {
                guard paths.contains(path) else { return false }
                waiting[path, default: []].append(send)
                return true
            }
        }

        /// Stops holding `path`; returns the answers it was holding back.
        func release(_ path: String) -> [@Sendable () -> Void] {
            lock.withLock {
                paths.remove(path)
                return waiting.removeValue(forKey: path) ?? []
            }
        }
    }

    deinit {
        listener.cancel()
    }
}
