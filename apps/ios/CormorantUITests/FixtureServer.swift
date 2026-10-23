import Foundation
import Network

/// Serves one fixed HTML page on 127.0.0.1 so the tests need no network. The app and the test
/// runner share the simulator's loopback. Every path gets the same page.
final class FixtureServer {
    struct StartFailed: Error {}

    let port: UInt16
    private let listener: NWListener

    init(html: String) throws {
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "FixtureServer")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            // Answer once the request starts arriving; its contents don't matter.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
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
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    deinit {
        listener.cancel()
    }
}
