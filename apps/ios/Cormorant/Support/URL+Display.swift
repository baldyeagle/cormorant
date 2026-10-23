import Foundation

extension URL {
    /// Host without a leading `www.`, for compact display. Falls back to the full string.
    var displayHost: String {
        guard let host = host(), !host.isEmpty else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
