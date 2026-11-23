import Foundation

/// A page that is a file WebKit shows itself (a PDF, an image, plain text) rather than a
/// web page. Share hands over the file, not its address, as Safari and Arc do, so Save to Files,
/// Markup and Print get the PDF itself.
public struct PageFile: Equatable, Sendable {
    public let url: URL
    /// What to call it: the server's name for it, else the address's, with an extension for its type.
    public let filename: String
    /// Lowercased, without parameters.
    public let mimeType: String
    /// Which edition of the file the page is: the server's `ETag`, else its `Last-Modified`; nil when
    /// it gives neither. A copy fetched for an earlier share is used again only for the same edition.
    public let version: String?
    /// Its size, when the server said; the toast counts up to it before the fetch has its own answer.
    public let expectedLength: Int64?

    /// Nil for a web page (HTML, XHTML), for a response that says nothing of its type, and for audio
    /// and video, which may be a stream with no end (a radio station): those share their address.
    public init?(url: URL, mimeType: String?, suggestedFilename: String?, version: String? = nil, expectedLength: Int64? = nil) {
        guard let type = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              type.contains("/"), !Self.webPageTypes.contains(type),
              !type.hasPrefix("audio/"), !type.hasPrefix("video/") else { return nil }
        self.url = url
        self.mimeType = type
        filename = DownloadNaming.filename(suggested: suggestedFilename, url: url, mimeType: type)
        self.version = version.flatMap { $0.isEmpty ? nil : $0 }
        self.expectedLength = expectedLength.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// From a response's headers: `ETag`, else `Last-Modified`.
    public static func version(etag: String?, lastModified: String?) -> String? {
        if let etag, !etag.isEmpty { return "etag:" + etag }
        if let lastModified, !lastModified.isEmpty { return "modified:" + lastModified }
        return nil
    }

    private static let webPageTypes: Set<String> = ["text/html", "application/xhtml+xml", "multipart/x-mixed-replace"]
}

/// How far a fetch has come, as a toast says it: "42.1 MB of 183.4 MB".
public enum TransferText {
    public static func line(received: Int64, expected: Int64?, locale: Locale = .current) -> String {
        let style = ByteCountFormatStyle(style: .file, locale: locale)
        guard received > 0 else { return "Starting…" } // Not "Zero kB of 183.4 MB".
        guard let expected, expected > 0 else { return received.formatted(style) }
        return "\(min(received, expected).formatted(style)) of \(expected.formatted(style))"
    }

    /// 0...1 for the bar, nil while the size isn't known.
    public static func fraction(received: Int64, expected: Int64?) -> Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}
