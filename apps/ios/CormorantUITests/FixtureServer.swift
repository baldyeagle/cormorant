import Foundation
import Network

/// Serves one fixed HTML page on 127.0.0.1 so the tests need no network. The app and the test
/// runner share the simulator's loopback. Every path gets the same page; `delays` holds some back.
/// Counts requests by path, so a test can tell a page that was loaded again from one that wasn't.
final class FixtureServer {
    struct StartFailed: Error {}

    let port: UInt16
    private let listener: NWListener
    private let counts: Counts

    /// - Parameter delays: seconds to wait before answering, by path (`/slow`).
    init(html: String, delays: [String: Double] = [:]) throws {
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        let response = Data(header.utf8) + body

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "FixtureServer")
        let counts = Counts()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            // Answer once the request starts arriving; only its path matters.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let path = data.flatMap(Self.path(of:))
                if let path { counts.add(path) }
                let send: @Sendable () -> Void = {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
                if let delay = path.flatMap({ delays[$0] }) {
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
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Requests received so far for `path` (`/next`).
    func requestCount(for path: String) -> Int { counts.count(for: path) }

    /// `GET /next HTTP/1.1` → `/next`.
    private static func path(of request: Data) -> String? {
        guard let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: Int] = [:]

        func add(_ path: String) { lock.withLock { byPath[path, default: 0] += 1 } }
        func count(for path: String) -> Int { lock.withLock { byPath[path, default: 0] } }
    }

    deinit {
        listener.cancel()
    }
}
