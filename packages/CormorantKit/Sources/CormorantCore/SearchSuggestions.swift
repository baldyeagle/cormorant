import Foundation

extension SearchEngine {
    /// Query-suggestion endpoints of the built-in engines, `{query}` where the text goes. All answer in
    /// the OpenSearch suggestions format (`["text", ["suggestion", ...]]`) and need no account.
    static let suggestionTemplates: [String: String] = [
        SearchEngine.duckDuckGo.id: "https://duckduckgo.com/ac/?q={query}&type=list",
        SearchEngine.google.id: "https://suggestqueries.google.com/complete/search?client=firefox&q={query}",
        SearchEngine.kagi.id: "https://kagi.com/api/autosuggest?q={query}",
        SearchEngine.bing.id: "https://api.bing.com/osjson.aspx?query={query}",
        SearchEngine.ecosia.id: "https://ac.ecosia.org/autocomplete?q={query}&type=list",
        SearchEngine.startpage.id: "https://www.startpage.com/osuggestions?q={query}",
    ]

    /// Whether the engine suggests queries as you type. Built-in engines only; a custom engine's
    /// template says nothing about where its suggestions live.
    public var offersSuggestions: Bool { suggestionsURL(for: "a") != nil }

    /// Where to ask the engine for suggestions for `text`, or nil if it offers none.
    public func suggestionsURL(for text: String) -> URL? {
        guard isBuiltIn, SearchEngine.builtIn.contains(where: { $0.id == id }),
              let template = Self.suggestionTemplates[id] else { return nil }
        return Self.fill(template, with: text)
    }
}

/// Asks a search engine what people search for that starts with some text.
///
/// Requests carry no cookies and leave nothing cached; a slow, failed or oversized answer is no
/// suggestions, never an error.
public struct SearchSuggestionClient: Sendable {
    public static let maxResponseBytes = 64 * 1024
    /// Longest suggestion kept; anything longer is noise in a one-line row.
    static let maxSuggestionLength = 200

    private let session: URLSession

    public init(timeout: TimeInterval = 2.5) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    /// Up to `limit` suggestions for `text` from `engine`, in the engine's order. Empty if the engine
    /// offers none, `text` may be an address (`mayAsk(about:)`), the request fails, or the task is
    /// cancelled.
    public func suggestions(for text: String, from engine: SearchEngine, limit: Int = 8) async -> [String] {
        guard Self.mayAsk(about: text, engine: engine), let url = engine.suggestionsURL(for: text) else { return [] }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= Int64(Self.maxResponseBytes) else { return [] }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxResponseBytes { return [] }
            }
            return Self.parse(data, limit: limit)
        } catch {
            return []
        }
    }

    /// Whether `text` can go to the engine: a search, and nothing that could be an address or part of
    /// one, typed or edited (an intranet host, `user:password@host`, a URL with a character deleted).
    /// So never anything with `@` or `://`, and never one word with `.`, `/` or `:` in it.
    public static func mayAsk(about text: String, engine: SearchEngine) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("@"), !text.contains("://") else { return false }
        if !text.contains(where: \.isWhitespace), text.contains(where: { "./:".contains($0) }) { return false }
        guard case .search = AddressResolver.resolve(text, engine: engine) else { return false }
        return true
    }

    /// The suggestions in an OpenSearch response: trimmed, single-line, without blanks or repeats
    /// (ignoring case), at most `limit`.
    static func parse(_ data: Data, limit: Int) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count >= 2,
              let items = root[1] as? [Any] else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for case let item as String in items {
            let text = item.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= maxSuggestionLength, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count == limit { break }
        }
        return result
    }
}
