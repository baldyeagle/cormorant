import Foundation

/// A search provider. `queryTemplate` contains `{query}` where the percent-encoded query goes.
public struct SearchEngine: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var queryTemplate: String
    public var isBuiltIn: Bool

    public init(id: String, name: String, queryTemplate: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.queryTemplate = queryTemplate
        self.isBuiltIn = isBuiltIn
    }

    public static let google = SearchEngine(id: "google", name: "Google", queryTemplate: "https://www.google.com/search?q={query}", isBuiltIn: true)
    public static let duckDuckGo = SearchEngine(id: "duckduckgo", name: "DuckDuckGo", queryTemplate: "https://duckduckgo.com/?q={query}", isBuiltIn: true)
    public static let kagi = SearchEngine(id: "kagi", name: "Kagi", queryTemplate: "https://kagi.com/search?q={query}", isBuiltIn: true)
    public static let bing = SearchEngine(id: "bing", name: "Bing", queryTemplate: "https://www.bing.com/search?q={query}", isBuiltIn: true)
    public static let ecosia = SearchEngine(id: "ecosia", name: "Ecosia", queryTemplate: "https://www.ecosia.org/search?q={query}", isBuiltIn: true)
    public static let startpage = SearchEngine(id: "startpage", name: "Startpage", queryTemplate: "https://www.startpage.com/do/search?q={query}", isBuiltIn: true)

    public static let builtIn: [SearchEngine] = [.duckDuckGo, .google, .kagi, .bing, .ecosia, .startpage]
    public static let `default`: SearchEngine = .duckDuckGo

    /// Search URL for `query`, or nil if the template is unusable. Only `http` and `https` results are
    /// returned, so a custom template such as `javascript:...{query}` can never run script.
    public func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, queryTemplate.contains(Self.placeholder),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
        else { return nil }
        let url = URL(string: queryTemplate.replacingOccurrences(of: Self.placeholder, with: encoded))
        guard let url, let scheme = url.scheme?.lowercased(), Self.allowedSchemes.contains(scheme),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    static let allowedSchemes: Set<String> = ["http", "https"]

    static let placeholder = "{query}"

    /// Characters left unescaped inside a query value: `urlQueryAllowed` minus the delimiters
    /// that would change the meaning of the query string.
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

/// Turns address-bar text into something to load.
public enum AddressResolver {
    public enum Resolution: Equatable, Sendable {
        case navigate(URL)
        case search(URL, query: String)
    }

    /// Navigate if the text is a URL or looks like a host, otherwise search with `engine`.
    /// Empty input returns nil.
    ///
    /// Navigates:
    /// - `http:`, `https:` (with a host) and `about:` URLs as typed. Other schemes, including `file:`,
    ///   `data:` and `javascript:`, are searched for: the address bar never opens local files or
    ///   inline documents.
    /// - Bare hosts with an optional port (1-65535) and path/query/fragment: `localhost`, IPv4
    ///   literals and bracketed IPv6 literals (`[::1]:8080`) get `http://`; dotted hostnames whose
    ///   last label is an IANA top-level domain (or `local`) get `https://`. A trailing dot
    ///   (`example.com.`) is allowed.
    /// - Unicode hostnames navigate to their IDNA (`xn--`) form when `URL(string:)` accepts them and
    ///   the converted name passes the same checks; otherwise they are searched.
    ///
    /// `name.ext` with nothing else, where `ext` is a TLD that is far more often a file extension
    /// (`README.md`, `setup.py`, `archive.zip`, `clip.mov`), is searched. Type `https://` to visit one.
    ///
    /// If `engine` has an unusable template, the search falls back to `SearchEngine.default`.
    public static func resolve(_ input: String, engine: SearchEngine) -> Resolution? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = explicitURL(text) { return .navigate(url) }
        if let url = bareHostURL(text) { return .navigate(url) }

        guard let url = engine.url(for: text) ?? SearchEngine.default.url(for: text) else { return nil }
        return .search(url, query: text)
    }

    static let navigableSchemes: Set<String> = ["http", "https", "about"]

    /// TLDs that, as the whole input `name.tld`, are far more likely a file name than a site.
    static let fileExtensionTLDs: Set<String> = ["md", "zip", "mov", "py"]

    /// Rule (a): text that starts with an allowed scheme and parses as a URL.
    static func explicitURL(_ text: String) -> URL? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        guard navigableSchemes.contains(scheme), let url = URL(string: text) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host(), !host.isEmpty else { return nil }
        }
        return url
    }

    /// Rule (b): a single token that is a bare host (see `resolve`), with an optional port and
    /// path/query/fragment.
    static func bareHostURL(_ text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }

        let authorityEnd = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        let authority = text[..<authorityEnd]
        let hasPathQueryOrFragment = authorityEnd != text.endIndex
        guard !authority.isEmpty, !authority.contains("@") else { return nil }

        if authority.first == "[" {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let literal = authority[authority.index(after: authority.startIndex)..<close]
            let afterBracket = authority[authority.index(after: close)...]
            guard isIPv6(literal) else { return nil }
            if !afterBracket.isEmpty {
                guard afterBracket.first == ":", isPort(afterBracket.dropFirst()) else { return nil }
            }
            return URL(string: "http://\(text)")
        }

        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        if parts.count == 2 {
            guard isPort(parts[1]) else { return nil }
        }
        var host = parts[0].lowercased()
        let hasTrailingDot = host.hasSuffix(".")
        if hasTrailingDot { host.removeLast() }
        guard !host.isEmpty else { return nil }

        if host == "localhost" || isIPv4(host) {
            return URL(string: "http://\(text)")
        }

        // `URL(string:)` converts a Unicode host to IDNA; validate the ASCII form it produced.
        guard let url = URL(string: "https://\(text)"),
              var asciiHost = url.host(percentEncoded: false)?.lowercased()
        else { return nil }
        if asciiHost.hasSuffix(".") { asciiHost.removeLast() }
        guard isPlausibleHostname(asciiHost) else { return nil }

        let labels = asciiHost.split(separator: ".")
        if labels.count == 2, parts.count == 1, !hasPathQueryOrFragment, !hasTrailingDot,
           let tld = labels.last, fileExtensionTLDs.contains(String(tld)) {
            return nil
        }
        return url
    }

    static func isPort(_ text: Substring) -> Bool {
        guard (1...5).contains(text.count), text.allSatisfy(\.isASCIIDigit), let port = Int(text) else {
            return false
        }
        return (1...65_535).contains(port)
    }

    static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            (1...3).contains(octet.count) && octet.allSatisfy(\.isASCIIDigit) && Int(octet)! <= 255
        }
    }

    static func isIPv6(_ literal: Substring) -> Bool {
        guard literal.contains(":"), literal.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        var address = in6_addr()
        return String(literal).withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    /// An ASCII hostname of at least two valid labels whose last label is an IANA TLD or `local`.
    static func isPlausibleHostname(_ host: String) -> Bool {
        guard host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last else { return false }
        let labelsValid = labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && label.first != "-" && label.last != "-"
        }
        guard labelsValid else { return false }
        return tld == "local" || ianaTopLevelDomains.contains(String(tld))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
