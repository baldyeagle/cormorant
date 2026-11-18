import Foundation
import UniformTypeIdentifiers

/// Names for downloaded files: what the server or page suggested, made safe to write into one folder,
/// and kept apart from files already there ("report.pdf", then "report (2).pdf").
public enum DownloadNaming {
    /// Longest name kept, in UTF-8 bytes (APFS allows 255; room is left for " (999)").
    static let maxBytes = 200

    /// A file name for a download: `suggested` (WebKit's, from `Content-Disposition` or the URL) with
    /// path separators, control characters and leading dots taken out; else the URL's last path
    /// component; else "Download". Given a MIME type and no extension, adds the type's usual one.
    public static func filename(suggested: String?, url: URL?, mimeType: String?) -> String {
        var name = clean(suggested ?? "")
        if name.isEmpty, let last = url?.lastPathComponent, last != "/" {
            name = clean(last.removingPercentEncoding ?? last)
        }
        if name.isEmpty { name = "Download" }
        let (base, ext) = split(name)
        if ext.isEmpty, let mimeType, let type = UTType(mimeType: mimeType.lowercased()),
           let preferred = type.preferredFilenameExtension {
            name = "\(base).\(preferred)"
        }
        return truncated(name)
    }

    /// `name`, or the first of "name (2).ext", "name (3).ext"… that `exists` says is free. A compound
    /// `.tar.gz` stays together.
    public static func unique(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let (base, ext) = split(name)
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var number = 2
        while true {
            let candidate = "\(base) (\(number))\(suffix)"
            if !exists(candidate) || number >= 10_000 { return candidate }
            number += 1
        }
    }

    /// Without "/", ":" (Finder shows it as "/"), control characters, and leading dots (hidden files)
    /// or spaces; runs of whitespace become one space.
    private static func clean(_ raw: String) -> String {
        let replaced = raw.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "_" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        let collapsed = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.drop { $0 == "." || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
    }

    /// "archive.tar.gz" → ("archive", "tar.gz"); "notes" → ("notes", "").
    static func split(_ name: String) -> (base: String, ext: String) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last, !last.isEmpty, !last.contains(" "), last.count <= 12 else {
            return (name, "")
        }
        if parts.count > 2, parts[parts.count - 2].lowercased() == "tar" {
            return (parts.dropLast(2).joined(separator: "."), "tar.\(last)")
        }
        return (parts.dropLast().joined(separator: "."), String(last))
    }

    /// Cut to `maxBytes` of UTF-8 from the end of the base, keeping the extension.
    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let (base, ext) = split(name)
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var kept = ""
        for character in base {
            if (kept + String(character) + suffix).utf8.count > maxBytes { break }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespaces) + suffix
    }
}
