import Foundation

/// A `<link rel="...icon...">` element read from a page.
public struct FaviconCandidate: Hashable, Sendable {
    /// Absolute URL (the element's resolved `href`).
    public var url: URL
    public var rel: String
    public var sizes: String?
    public var type: String?

    public init(url: URL, rel: String, sizes: String? = nil, type: String? = nil) {
        self.url = url
        self.rel = rel
        self.sizes = sizes
        self.type = type
    }
}

/// Picks which of a page's declared icons to download, best first.
public enum FaviconSelector {
    /// URLs to try in order: apple-touch icons (largest first), then `icon` links of 32 px or more
    /// (largest first), then `icon` links with no stated size, then smaller ones, then
    /// `/favicon.ico` on the page's origin, always last. Skipped: SVG (UIImage can't decode it),
    /// anything not http(s), plain http from an https page (a network attacker could swap it), and
    /// icons on other sites. The app fetches icons itself, outside WebKit's content blockers, so a
    /// third-party icon URL could be a tracker or a probe of the local network; the page's own host
    /// and its subdomains are the site's to serve. Empty only when `pageURL` itself isn't http(s).
    public static func best(from candidates: [FaviconCandidate], pageURL: URL) -> [URL] {
        guard let origin = webOrigin(of: pageURL) else { return [] }
        let fallback = origin.appending(path: "favicon.ico")
        let pageIsSecure = pageURL.scheme?.lowercased() == "https"
        let site = siteHost(of: pageURL)
        let ranked = candidates.enumerated().compactMap { index, candidate -> Ranked? in
            guard isWeb(candidate.url), !isSVG(candidate), candidate.url != fallback else { return nil }
            if pageIsSecure, candidate.url.scheme?.lowercased() != "https" { return nil }
            guard let site, let host = candidate.url.host()?.lowercased(), host == site || host.hasSuffix("." + site)
            else { return nil }
            let tokens = Set(candidate.rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let size = largestSize(in: candidate.sizes)
            let tier: Int
            let rankSize: Int
            if !tokens.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"]) {
                // Unsized touch icons are almost always the 180 px iOS default.
                tier = 0
                rankSize = size ?? 180
            } else if tokens.contains("icon") {
                switch size {
                case let size? where size >= minimumSize: tier = 1
                case nil: tier = 2
                default: tier = 3
                }
                rankSize = size ?? 0
            } else {
                return nil
            }
            return Ranked(url: candidate.url, tier: tier, size: rankSize, index: index)
        }
        .sorted { ($0.tier, -$0.size, $0.index) < ($1.tier, -$1.size, $1.index) }

        var seen = Set<URL>()
        var urls: [URL] = []
        for url in ranked.map(\.url) + [fallback] where seen.insert(url).inserted {
            urls.append(url)
        }
        return urls
    }

    /// The cache key for a page's icon: its host lowercased, without a leading `www.`, and prefixed
    /// `http:` for plain-http pages so an icon fetched in the clear never shows on the https site.
    /// Nil for URLs with no host.
    public static func hostKey(for url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return url.scheme?.lowercased() == "http" ? "http:" + host : host
    }

    /// Loopback, private, link-local, shared-address and unspecified IPs in any spelling a resolver
    /// accepts (IPv4-mapped and NAT64 IPv6, shorthand and hex IPv4), and names that only resolve on
    /// a local network (`localhost`, `.local`, single-label names).
    public static func isLocal(host: String) -> Bool {
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            let embedsV4 = bytes[0..<10].allSatisfy { $0 == 0 } && (bytes[10..<12].allSatisfy { $0 == 0 } || bytes[10..<12].allSatisfy { $0 == 0xff })
            let nat64 = bytes[0..<4] == [0x00, 0x64, 0xff, 0x9b] && bytes[4..<12].allSatisfy { $0 == 0 }
            if embedsV4 || nat64 { return isLocal(ipv4: Array(bytes[12..<16])) }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 != 0) // ULA, link/site-local
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return isLocal(ipv4: withUnsafeBytes(of: &v4) { Array($0) })
        }
        // Anything numeric that isn't a plain dotted quad ("127.1", "0x7f.1", "2130706433") is an
        // address to some resolver; none is a real site's name.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) || ($0.hasPrefix("0x") && $0.dropFirst(2).allSatisfy(\.isHexDigit)) }) {
            return true
        }
        if labels.count == 1 { return true }
        return ["local", "localhost", "internal", "home.arpa", "lan"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        switch (bytes[0], bytes[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127): true
        default: false
        }
    }

    /// The page's host without a leading `www.`: icons from it or its subdomains count as the site's.
    private static func siteHost(of url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return host
    }

    /// Below this, a declared icon looks blurry next to an unsized one (often a multi-size ICO).
    static let minimumSize = 32
    /// What `sizes="any"` ranks as: scalable, so as good as the largest raster.
    static let anySize = 1024

    private struct Ranked {
        let url: URL
        let tier: Int
        let size: Int
        let index: Int
    }

    /// Largest dimension in a `sizes` attribute ("16x16 32x32", "any"); nil if absent or unparseable.
    static func largestSize(in sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let values = sizes.lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> Int? in
            if token == "any" { return anySize }
            let parts = token.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0 else { return nil }
            return max(width, height)
        }
        return values.max()
    }

    private static func isSVG(_ candidate: FaviconCandidate) -> Bool {
        if let type = candidate.type?.lowercased(), type.contains("svg") { return true }
        return candidate.url.pathExtension.lowercased() == "svg"
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return url.host().map { !$0.isEmpty } ?? false
    }

    /// `scheme://host[:port]/` of an http(s) URL.
    private static func webOrigin(of url: URL) -> URL? {
        guard isWeb(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
