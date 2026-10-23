import CryptoKit
import Foundation

/// What we remember about a cached filter list (`lists/<source>.meta.json`).
public struct FilterListMetadata: Codable, Sendable, Equatable {
    public var etag: String?
    public var lastFetched: Date?
    public var byteCount: Int
    /// Rules emitted by the converter (before chunking duplicated exceptions).
    public var ruleCount: Int
    public var skippedCount: Int
    /// `WKContentRuleListStore` identifiers compiled from the cached text.
    public var identifiers: [String]
    /// `ABPFilterConverter.converterVersion` that produced `identifiers` (nil: written before versioning).
    /// Lists from another version are recompiled even when the list text is unchanged.
    public var converterVersion: Int?
    /// Rules WebKit rejected and that were dropped while compiling, per compiled-list identifier.
    public var droppedRulesByIdentifier: [String: Int] = [:]

    /// Total rules dropped because WebKit rejected them (see `droppedRulesByIdentifier`).
    public var droppedRuleCount: Int {
        identifiers.reduce(0) { $0 + (droppedRulesByIdentifier[$1] ?? 0) }
    }

    public init(etag: String? = nil, lastFetched: Date? = nil, byteCount: Int = 0, ruleCount: Int = 0,
                skippedCount: Int = 0, identifiers: [String] = []) {
        self.etag = etag
        self.lastFetched = lastFetched
        self.byteCount = byteCount
        self.ruleCount = ruleCount
        self.skippedCount = skippedCount
        self.identifiers = identifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastFetched = try container.decodeIfPresent(Date.self, forKey: .lastFetched)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        ruleCount = try container.decodeIfPresent(Int.self, forKey: .ruleCount) ?? 0
        skippedCount = try container.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
        identifiers = try container.decodeIfPresent([String].self, forKey: .identifiers) ?? []
        converterVersion = try container.decodeIfPresent(Int.self, forKey: .converterVersion)
        droppedRulesByIdentifier = try container.decodeIfPresent([String: Int].self, forKey: .droppedRulesByIdentifier) ?? [:]
    }
}

public enum ContentBlockingError: Error, LocalizedError, Equatable, Sendable {
    /// Nothing could be fetched, loaded from cache, or compiled (e.g. offline on first launch).
    /// Callers should load the page without blocking rather than fail.
    case noRuleListsAvailable(reasons: [String])
    case httpStatus(source: FilterListSource, code: Int)
    /// The server answered with something that is not a filter list (captive portal page, empty body).
    case invalidListContent(source: FilterListSource)
    case noCachedList(source: FilterListSource)
    case emptyConversion(source: FilterListSource)
    case compileFailed(identifier: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .noRuleListsAvailable(let reasons):
            "No content blocking lists are available yet (offline and nothing cached?). "
                + reasons.joined(separator: "; ")
        case .httpStatus(let source, let code): "\(source.displayName): server returned HTTP \(code)."
        case .invalidListContent(let source): "\(source.displayName): download was not a filter list."
        case .noCachedList(let source): "\(source.displayName): nothing cached."
        case .emptyConversion(let source): "\(source.displayName): no usable rules after conversion."
        case .compileFailed(let identifier, let message): "WebKit rejected \(identifier): \(message)"
        }
    }
}

/// File and network work for the engine. Everything here is nonisolated and runs off the main actor.
enum FilterListCache {
    struct FetchOutcome: Sendable {
        /// The cached text changed (so compiled lists must be rebuilt).
        var changed: Bool
        var metadata: FilterListMetadata
        /// Set when the network failed but a cached copy was used.
        var fetchError: String?
    }

    struct PreparedChunk: Sendable {
        var identifier: String
        var json: String
        /// Kept so a chunk WebKit rejects can be bisected to drop only the offending rules.
        var rules: [ContentRule]
        var ruleCount: Int { rules.count }
    }

    struct PreparedList: Sendable {
        var chunks: [PreparedChunk]
        var ruleCount: Int
        var skippedCount: Int
        var byteCount: Int
        var summary: String
    }

    static let identifierPrefix = "cormorant."

    static func listsDirectory(in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent("lists", isDirectory: true)
    }

    static func textURL(_ source: FilterListSource, in cacheDirectory: URL) -> URL {
        listsDirectory(in: cacheDirectory).appendingPathComponent("\(source.rawValue).txt")
    }

    static func metadataURL(_ source: FilterListSource, in cacheDirectory: URL) -> URL {
        listsDirectory(in: cacheDirectory).appendingPathComponent("\(source.rawValue).meta.json")
    }

    static func identifierPrefix(for source: FilterListSource) -> String {
        "\(identifierPrefix)\(source.rawValue)."
    }

    static func readMetadata(_ source: FilterListSource, in cacheDirectory: URL) -> FilterListMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(source, in: cacheDirectory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FilterListMetadata.self, from: data)
    }

    static func writeMetadata(_ metadata: FilterListMetadata, for source: FilterListSource, in cacheDirectory: URL) throws {
        try FileManager.default.createDirectory(at: listsDirectory(in: cacheDirectory), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL(source, in: cacheDirectory), options: .atomic)
    }

    static func hasCachedText(_ source: FilterListSource, in cacheDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: textURL(source, in: cacheDirectory).path)
    }

    /// Fetches `source` unless the cache is younger than `maxAge` (or `force`). Sends `If-None-Match`
    /// when an etag is cached. Network failures fall back to the cached copy when there is one.
    @concurrent
    static func fetch(_ source: FilterListSource, cacheDirectory: URL, session: URLSession, force: Bool,
                      maxAge: TimeInterval) async throws -> FetchOutcome {
        let textURL = textURL(source, in: cacheDirectory)
        let hasText = hasCachedText(source, in: cacheDirectory)
        let cached = readMetadata(source, in: cacheDirectory)
        if !force, hasText, let cached, let lastFetched = cached.lastFetched, Date().timeIntervalSince(lastFetched) < maxAge {
            return FetchOutcome(changed: false, metadata: cached, fetchError: nil)
        }

        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if hasText, let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 304 && hasText {
                var metadata = cached ?? FilterListMetadata(byteCount: fileSize(textURL))
                metadata.lastFetched = Date()
                try writeMetadata(metadata, for: source, in: cacheDirectory)
                // Without metadata we never compiled this text: treat as changed.
                return FetchOutcome(changed: cached == nil, metadata: metadata, fetchError: nil)
            }
            guard (200..<300).contains(code) else { throw ContentBlockingError.httpStatus(source: source, code: code) }
            guard looksLikeFilterList(data) else { throw ContentBlockingError.invalidListContent(source: source) }

            let previous = hasText ? try? Data(contentsOf: textURL) : nil
            try FileManager.default.createDirectory(at: listsDirectory(in: cacheDirectory), withIntermediateDirectories: true)
            if previous != data { try data.write(to: textURL, options: .atomic) }
            let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            var metadata = cached ?? FilterListMetadata()
            metadata.etag = etag
            metadata.lastFetched = Date()
            metadata.byteCount = data.count
            try writeMetadata(metadata, for: source, in: cacheDirectory)
            return FetchOutcome(changed: previous != data || cached == nil, metadata: metadata, fetchError: nil)
        } catch {
            guard hasText else { throw error }
            let metadata = cached ?? FilterListMetadata(byteCount: fileSize(textURL))
            return FetchOutcome(changed: cached == nil, metadata: metadata, fetchError: error.localizedDescription)
        }
    }

    /// Reads cached text, converts, chunks, and serializes. CPU-heavy; runs off the main actor.
    @concurrent
    static func prepare(_ source: FilterListSource, cacheDirectory: URL, maxPerList: Int = 150_000) async throws -> PreparedList {
        let url = textURL(source, in: cacheDirectory)
        guard let data = try? Data(contentsOf: url) else { throw ContentBlockingError.noCachedList(source: source) }
        let text = String(decoding: data, as: UTF8.self)
        let conversion = ABPFilterConverter.convertPartitioned(text)
        // Network and cosmetic rules go in separate WebKit lists so network exceptions
        // (`ignore-previous-rules`) cannot cancel element hiding on the page they match.
        let chunks = ABPFilterConverter.chunk(conversion.network, maxPerList: maxPerList)
            + ABPFilterConverter.chunk(conversion.cosmetic, maxPerList: maxPerList)
        guard !chunks.isEmpty else { throw ContentBlockingError.emptyConversion(source: source) }
        let prepared = chunks.enumerated().map { index, rules in
            let json = ContentRule.encodedRuleList(rules)
            return PreparedChunk(identifier: identifier(for: source, chunk: index, json: json), json: json, rules: rules)
        }
        return PreparedList(
            chunks: prepared,
            ruleCount: conversion.network.count + conversion.cosmetic.count,
            skippedCount: conversion.statistics.skippedTotal,
            byteCount: data.count,
            summary: conversion.statistics.summary
        )
    }

    /// `cormorant.<source>.v<converterVersion>.<chunk>.<contentHash>`.
    static func identifier(for source: FilterListSource, chunk: Int, json: String) -> String {
        "\(identifierPrefix(for: source))v\(ABPFilterConverter.converterVersion).\(chunk).\(contentHash(json))"
    }

    static func contentHash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Rejects captive-portal HTML and empty bodies.
    static func looksLikeFilterList(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0xEF && $0 != 0xBB && $0 != 0xBF }) else {
            return false
        }
        return first != UInt8(ascii: "<")
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
