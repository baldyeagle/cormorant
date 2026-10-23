import Foundation
import Synchronization
import Testing
import WebKit
@testable import CormorantBlocking

enum TestResources {
    static func easyListExcerpt() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "easylist-excerpt", withExtension: "txt", subdirectory: "Resources"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A fresh directory under the system temp dir. Callers remove it (see `removeDirectory`) in a `defer`.
    static func temporaryDirectory(_ label: String = "test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cormorant-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Counts stubbed requests per filter list source; safe to update from URL loading threads.
final class RequestCounter: Sendable {
    private let storage = Mutex<[FilterListSource: Int]>([:])

    func record(_ source: FilterListSource) { storage.withLock { $0[source, default: 0] += 1 } }
    var counts: [FilterListSource: Int] { storage.withLock { $0 } }
}

/// A minimal model of how WebKit evaluates one compiled list for one request, enough to check rule
/// ordering: rules run in order, a matching `block` blocks, and a matching `ignore-previous-rules`
/// cancels every earlier match. A request is blocked if any list blocks it.
enum RuleEvaluator {
    struct Request {
        var url: String
        var resourceType: String
        var pageHost: String
        var thirdParty = true
    }

    static func isBlocked(_ request: Request, lists: [[ContentRule]]) throws -> Bool {
        try lists.contains { try isBlocked(request, by: $0) }
    }

    static func isBlocked(_ request: Request, by rules: [ContentRule]) throws -> Bool {
        var blocked = false
        for rule in rules where try matches(rule.trigger, request) {
            switch rule.action.type {
            case ContentRule.Action.block.type: blocked = true
            case ContentRule.Action.ignorePrevious.type: blocked = false
            default: break
            }
        }
        return blocked
    }

    private static func matches(_ trigger: ContentRule.Trigger, _ request: Request) throws -> Bool {
        let options: NSRegularExpression.Options = trigger.urlFilterIsCaseSensitive == true ? [] : [.caseInsensitive]
        let regex = try NSRegularExpression(pattern: trigger.urlFilter, options: options)
        let url = request.url
        guard regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { return false }
        if let types = trigger.resourceType, !types.contains(request.resourceType) { return false }
        if let load = trigger.loadType, !load.contains(request.thirdParty ? "third-party" : "first-party") { return false }
        if let ifDomain = trigger.ifDomain, !ifDomain.contains(where: { domain($0, matches: request.pageHost) }) { return false }
        if let unlessDomain = trigger.unlessDomain, unlessDomain.contains(where: { domain($0, matches: request.pageHost) }) {
            return false
        }
        return true
    }

    /// `*a.com` matches `a.com` and its subdomains; `a.com` matches only itself.
    private static func domain(_ entry: String, matches host: String) -> Bool {
        guard entry.hasPrefix("*") else { return host == entry }
        let bare = String(entry.dropFirst())
        return host == bare || host.hasSuffix("." + bare)
    }
}

/// Compiles rules with a real `WKContentRuleListStore` backed by a temp directory.
@MainActor
struct WebKitCompiler {
    let directory: URL
    let store: WKContentRuleListStore

    init() throws {
        directory = try TestResources.temporaryDirectory("store")
        store = try #require(WKContentRuleListStore(url: directory))
    }

    /// Deletes the store directory. Call from a `defer` so the store outlives every use.
    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    func compile(json: String, identifier: String = "test.\(UUID().uuidString)") async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, any Error>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    func compile(_ rules: [ContentRule], identifier: String = "test.\(UUID().uuidString)") async throws -> WKContentRuleList {
        try await compile(json: ContentRule.encodedRuleList(rules), identifier: identifier)
    }

    /// Compiles; on failure, bisects to find the rules WebKit rejects and records them in the issue.
    @discardableResult
    func expectCompiles(_ rules: [ContentRule], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) async -> WKContentRuleList? {
        do {
            return try await compile(rules)
        } catch {
            let offenders = await invalidRules(in: rules, limit: 10)
            let described = offenders.map { ContentRule.encodedRuleList([$0]) }.joined(separator: "\n")
            Issue.record("\(label): WebKit rejected the list (\(error)). Offending rules:\n\(described)", sourceLocation: sourceLocation)
            return nil
        }
    }

    func invalidRules(in rules: [ContentRule], limit: Int) async -> [ContentRule] {
        guard !rules.isEmpty else { return [] }
        if (try? await compile(rules)) != nil { return [] }
        if rules.count == 1 { return rules }
        let middle = rules.count / 2
        var found = await invalidRules(in: Array(rules[..<middle]), limit: limit)
        if found.count < limit {
            found += await invalidRules(in: Array(rules[middle...]), limit: limit - found.count)
        }
        return found
    }

    func availableIdentifiers() async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
    }
}

/// Serves canned responses to a `URLSession`, keyed per session so parallel tests don't collide.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    typealias Handler = @Sendable (URLRequest) -> Result<Response, URLError>

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let headerName = "X-Cormorant-Stub"

    /// A session whose every request is answered by `handler`. Without a handler, every request fails as offline.
    static func session(_ handler: @escaping Handler = { _ in .failure(URLError(.notConnectedToInternet)) }) -> URLSession {
        let key = UUID().uuidString
        handlers.withLock { $0[key] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [headerName: key]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: Self.headerName) ?? ""
        let handler = Self.handlers.withLock { $0[key] }
        let result = handler?(request) ?? .failure(URLError(.notConnectedToInternet))
        switch result {
        case .success(let response):
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension ContentRule {
    static func blockRule(_ filter: String, caseSensitive: Bool? = nil, types: [String]? = nil, load: [String]? = nil,
                          ifDomain: [String]? = nil, unlessDomain: [String]? = nil) -> ContentRule {
        ContentRule(trigger: Trigger(urlFilter: filter, urlFilterIsCaseSensitive: caseSensitive, resourceType: types,
                                     loadType: load, ifDomain: ifDomain, unlessDomain: unlessDomain), action: .block)
    }

    static func exceptionRule(_ filter: String, types: [String]? = nil, load: [String]? = nil,
                              ifDomain: [String]? = nil, unlessDomain: [String]? = nil) -> ContentRule {
        ContentRule(trigger: Trigger(urlFilter: filter, resourceType: types, loadType: load, ifDomain: ifDomain,
                                     unlessDomain: unlessDomain), action: .ignorePrevious)
    }

    static func hideRule(_ selector: String, ifDomain: [String]? = nil, unlessDomain: [String]? = nil) -> ContentRule {
        ContentRule(trigger: Trigger(urlFilter: ".*", ifDomain: ifDomain, unlessDomain: unlessDomain), action: .hide(selector))
    }
}
