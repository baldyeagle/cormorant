#if DEBUG
import Foundation
import Network
import os

/// A minimal HTTP/1.1 server for the dev bridge's one endpoint, `POST /mcp`, on 127.0.0.1 only. Every
/// request needs the bearer token, and any with an `Origin` (a web page, or DNS rebinding) or a `Host`
/// other than the loopback address is refused before the token is looked at. One request per
/// connection: each response closes it.
nonisolated final class DevBridgeServer: @unchecked Sendable {
    /// A JSON-RPC message in; the response to send, or nil for 202 Accepted (a notification).
    typealias Handler = @Sendable (Data) async -> Data?
    /// Whether the listener has the port (false: it failed).
    typealias Listening = @Sendable (Bool) -> Void

    let port: UInt16
    private let token: Data
    private let handle: Handler
    private let listening: Listening
    private let listener: NWListener
    /// Open connections, at most `maxConnections`. Only touched on `queue`.
    private var connections = 0
    private let queue = DispatchQueue(label: "dev.baldyeagle.cormorant.dev-bridge")
    private static let log = Logger(subsystem: "dev.baldyeagle.cormorant", category: "DevBridge")

    private static let maxHeader = 32 * 1024
    private static let maxBody = 4 * 1024 * 1024
    private static let maxConnections = 8
    /// A connection that hasn't sent a whole request by then is dropped (answering can take longer).
    private static let requestDeadline: TimeInterval = 30

    init(port: UInt16, token: String, handle: @escaping Handler, listening: @escaping Listening) throws {
        self.port = port
        self.token = Data(token.utf8)
        self.handle = handle
        self.listening = listening
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [listening] state in
            switch state {
            case .ready: listening(true)
            case .failed(let error):
                Self.log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                listening(false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    /// Whether a connection's request has all arrived. Only touched on `queue`.
    private final class Reading: @unchecked Sendable {
        var isDone = false
    }

    private func serve(_ connection: NWConnection) {
        guard connections < Self.maxConnections else { return connection.cancel() }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections -= 1
            default: break
            }
        }
        let reading = Reading()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) {
            if !reading.isDone { connection.cancel() }
        }
        receive(on: connection, buffer: Data(), reading: reading)
    }

    private func receive(on connection: NWConnection, buffer: Data, reading: Reading) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Request.parse(buffer, maxHeader: Self.maxHeader, maxBody: Self.maxBody) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer, reading: reading)
                }
            case .invalid(let status):
                reading.isDone = true
                send(Response(status: status), on: connection)
            case .complete(let request):
                reading.isDone = true
                Task { [self] in send(await respond(to: request), on: connection) }
            }
        }
    }

    private func respond(to request: Request) async -> Response {
        guard request.path == "/mcp" else { return Response(status: 404) }
        // Browsers send an Origin with every cross-site request and every POST; nothing else that
        // should reach this does.
        guard request.headers["origin"] == nil else {
            Self.log.notice("Refused a request with an Origin")
            return Response(status: 403)
        }
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return Response(status: 421)
        }
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer "),
              Self.constantTimeEqual(Data(authorization.dropFirst("Bearer ".count).utf8), token) else {
            Self.log.notice("Refused a request without the token")
            return Response(status: 401)
        }
        guard request.method == "POST" else { return Response(status: 405, headers: ["Allow": "POST"]) }
        guard let body = await handle(request.body) else { return Response(status: 202) }
        return Response(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func send(_ response: Response, on connection: NWConnection) {
        connection.send(content: response.encoded, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    struct Request {
        let method: String
        let path: String
        /// Names lowercased.
        let headers: [String: String]
        let body: Data

        enum Parsed {
            case incomplete
            case invalid(Int)
            case complete(Request)
        }

        static func parse(_ buffer: Data, maxHeader: Int, maxBody: Int) -> Parsed {
            guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > maxHeader ? .invalid(431) : .incomplete
            }
            guard end.lowerBound <= maxHeader,
                  let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(431) }
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(400) }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                // Sent twice, it's refused rather than guessed at.
                guard headers[name] == nil else { return .invalid(400) }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { return .invalid(411) }
            let length = headers["content-length"].map { Int($0) } ?? 0
            guard let length, length >= 0 else { return .invalid(400) }
            guard length <= maxBody else { return .invalid(413) }
            let bodyStart = end.upperBound
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
            let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            return .complete(Request(method: String(requestLine[0]), path: path, headers: headers,
                                     body: buffer[bodyStart..<(bodyStart + length)]))
        }
    }

    struct Response {
        let status: Int
        var headers: [String: String] = [:]
        var body = Data()

        private static let reasons = [
            200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 411: "Length Required", 413: "Content Too Large", 421: "Misdirected Request",
            431: "Request Header Fields Too Large",
        ]

        var encoded: Data {
            var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
            var all = headers
            all["Content-Length"] = String(body.count)
            all["Connection"] = "close"
            all["Cache-Control"] = "no-store"
            for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            return Data(head.utf8) + body
        }
    }
}
#endif
