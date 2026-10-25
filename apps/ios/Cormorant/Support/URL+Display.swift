import Foundation

extension URL {
    /// Host without a leading `www.`, for compact display. Falls back to the full string.
    var displayHost: String {
        guard let host = host(), !host.isEmpty else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The whole address without the scheme, any user name or password, a leading `www.` or a bare
    /// trailing slash.
    var displayString: String {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        var string = components?.string ?? absoluteString
        if let scheme, string.lowercased().hasPrefix(scheme.lowercased() + "://") {
            string.removeFirst(scheme.count + 3)
        }
        if string.hasPrefix("www.") { string.removeFirst(4) }
        if string.hasSuffix("/"), path() == "/", query() == nil, fragment() == nil { string.removeLast() }
        return string
    }
}
