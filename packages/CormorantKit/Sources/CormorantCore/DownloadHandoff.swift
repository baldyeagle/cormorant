import Foundation

/// A downloaded file the browser opens in a system viewer rather than keeping in Downloads, as Safari
/// does: a Wallet pass, a calendar file, a 3D model for AR Quick Look.
public enum DownloadHandoff: Equatable, Sendable {
    /// `.pkpass`: Add to Wallet.
    case walletPass
    /// `.ics`: the New Event editor, an event at a time.
    case calendar
    /// `.usdz` / `.reality`: AR Quick Look, what a page's "View in AR" (`<a rel="ar">`) links to.
    case arModel

    /// From the response's MIME type, or failing that the file's extension (servers often send these
    /// as `application/octet-stream`).
    public init?(mimeType: String?, filename: String) {
        let type = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()
        // A page, whatever its address ends in (`/events.ics` serving an HTML calendar view).
        if type == "text/html" || type == "application/xhtml+xml" { return nil }
        if type == "application/vnd.apple.pkpass" || ext == "pkpass" {
            self = .walletPass
        } else if type == "text/calendar" || ext == "ics" {
            self = .calendar
        } else if Self.arTypes.contains(type) || ext == "usdz" || ext == "reality" {
            self = .arModel
        } else {
            return nil
        }
    }

    private static let arTypes: Set<String> = [
        "model/vnd.usdz+zip", "model/usd", "model/vnd.pixar.usd", "model/vnd.reality",
    ]

    /// A `Content-Disposition` that says to save the response rather than show it.
    public static func isAttachment(contentDisposition: String?) -> Bool {
        guard let contentDisposition else { return false }
        return contentDisposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
    }
}
