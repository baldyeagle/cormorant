#if DEBUG
import AppKit
import CormorantBrowser
import os
import Security
import WebKit

/// Debug builds only, and only when launched with `-devBridge`: an MCP server on 127.0.0.1 that lets a
/// coding agent see the app (its state, the page, the window with the page pasted in) and drive it
/// (tabs, Spaces, the sidebar and bar, appearance, window size, trackpad swipes fed in-process).
/// The token is in the container's Application Support/DevBridge/token.
final class DevBridge {
    private static var shared: DevBridge?
    /// The sidebar has slid out over the page (pointer at the left edge). Reported whether or not the
    /// bridge is on: the window can come up first.
    static var sidebarPeeks = false

    let app: AppDelegate
    let folder: URL
    private var server: DevBridgeServer?
    private var tools: DevBridgeTools?
    private static let log = Logger(subsystem: "dev.baldyeagle.cormorant", category: "DevBridge")

    static let defaultPort: UInt16 = 47321

    private init(app: AppDelegate, folder: URL) {
        self.app = app
        self.folder = folder
    }

    static func startIfAsked(app: AppDelegate) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-devBridge") else { return }
        let asked = arguments.firstIndex(of: "-devBridgePort").flatMap { index in
            arguments.indices.contains(index + 1) ? UInt16(arguments[index + 1]) : nil
        }
        let port = asked.flatMap { $0 > 0 ? $0 : nil } ?? defaultPort
        let folder = URL.applicationSupportDirectory.appending(path: "DevBridge", directoryHint: .isDirectory)
        let endpointFile = folder.appending(path: "endpoint.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let token = try loadToken(in: folder)
            let bridge = DevBridge(app: app, folder: folder)
            let tools = DevBridgeTools(bridge: bridge)
            let mcp = DevBridgeMCP(tools: tools)
            let server = try DevBridgeServer(port: port, token: token, handle: { body in await mcp.handle(body) },
                                             listening: { listening in
                Task { @MainActor in didListen(listening, port: port, endpointFile: endpointFile) }
            })
            bridge.tools = tools
            bridge.server = server
            server.start()
            shared = bridge
        } catch {
            log.fault("Dev bridge didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Says where the bridge is once it's listening. Every Debug build shares the container, so a second
    /// one running can't take the port: it says so, and leaves the first one's file alone.
    private static func didListen(_ listening: Bool, port: UInt16, endpointFile: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard listening else {
            log.fault("Dev bridge couldn't listen on port \(port, privacy: .public); another Cormorant may have it")
            return
        }
        let endpoint: [String: Any] = ["url": "http://127.0.0.1:\(port)/mcp", "pid": pid,
                                       "executable": Bundle.main.executablePath ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: endpoint, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: endpointFile, options: .atomic)
        }
        log.notice("Dev bridge on 127.0.0.1:\(port, privacy: .public), files in \(endpointFile.deletingLastPathComponent().path, privacy: .public)")
    }

    /// Kept across launches so the agent's config keeps working; delete the file for a new one.
    private static func loadToken(in folder: URL) throws -> String {
        let file = folder.appending(path: "token")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count == 64, saved.allSatisfy(\.isHexDigit) {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        guard (try? String(contentsOf: file, encoding: .utf8)) == token else { throw CocoaError(.fileWriteUnknown) }
        return token
    }

    var commands: WindowCommands { app.commands }
    var store: BrowserStore { app.store }
    var pageArea: DevBridgePageArea? { app.platform.backgroundStage as? DevBridgePageArea }
    var window: NSWindow? { pageArea?.window }
}

/// What the bridge needs of the page area.
protocol DevBridgePageArea: NSView {
    /// The active tab's web view, on screen.
    var shownWebView: WKWebView? { get }
    /// The rounded view holding it, which the back/forward swipe moves.
    var pageView: NSView { get }
    var isSwiping: Bool { get }
}

struct DevBridgeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// JSON-RPC over the server: `initialize`, `ping`, `tools/list` and `tools/call`. Tool calls run one at
/// a time, in the order they came: an agent may send several at once, and gestures can't interleave.
final class DevBridgeMCP {
    private let tools: DevBridgeTools
    private var isCalling = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    init(tools: DevBridgeTools) {
        self.tools = tools
    }

    func handle(_ body: Data) async -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let message = parsed as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Not a single request"]])
        }
        // A notification, or a response to a request this server never makes.
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            result = [
                "protocolVersion": asked.flatMap { Self.versions.contains($0) ? $0 : nil } ?? Self.versions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "cormorant-dev-bridge", "version": "1"],
                "instructions": DevBridgeTools.instructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools.list]
        case "tools/call":
            guard let name = params["name"] as? String, tools.has(name) else {
                return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "No such tool"]])
            }
            if isCalling { await withCheckedContinuation { waiting.append($0) } }
            isCalling = true
            result = await tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:])
            if waiting.isEmpty { isCalling = false } else { waiting.removeFirst().resume() }
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "No method \(method)"]])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Couldn't encode the response"}}"#.utf8)
    }
}
#endif
