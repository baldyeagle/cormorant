import Foundation
import Testing
@testable import CormorantCore

@Suite struct DownloadNamingTests {
    @Test func keepsASafeSuggestedName() {
        #expect(DownloadNaming.filename(suggested: "Report Q3.pdf", url: nil, mimeType: "application/pdf") == "Report Q3.pdf")
    }

    @Test func takesOutPathsHiddenDotsAndControlCharacters() {
        #expect(DownloadNaming.filename(suggested: "../../etc/passwd", url: nil, mimeType: nil) == "_.._etc_passwd")
        #expect(DownloadNaming.filename(suggested: ".bashrc", url: nil, mimeType: nil) == "bashrc")
        #expect(DownloadNaming.filename(suggested: "a\u{0}b\nc.txt", url: nil, mimeType: nil) == "a b c.txt")
        #expect(DownloadNaming.filename(suggested: "C:\\temp\\x.zip", url: nil, mimeType: nil) == "C__temp_x.zip")
    }

    @Test func fallsBackToTheURLThenToDownload() {
        let url = URL(string: "https://example.com/files/My%20Notes.txt")!
        #expect(DownloadNaming.filename(suggested: "", url: url, mimeType: nil) == "My Notes.txt")
        #expect(DownloadNaming.filename(suggested: nil, url: URL(string: "https://example.com/")!, mimeType: nil) == "Download")
        #expect(DownloadNaming.filename(suggested: "...", url: nil, mimeType: nil) == "Download")
    }

    @Test func addsTheTypesExtensionWhenThereIsNone() {
        #expect(DownloadNaming.filename(suggested: "invoice", url: nil, mimeType: "application/pdf") == "invoice.pdf")
        #expect(DownloadNaming.filename(suggested: "invoice", url: nil, mimeType: "application/x-unknown-thing") == "invoice")
        #expect(DownloadNaming.filename(suggested: "photo.jpeg", url: nil, mimeType: "image/png") == "photo.jpeg")
    }

    @Test func capsLongNamesKeepingTheExtension() {
        let long = String(repeating: "é", count: 300) + ".zip"
        let name = DownloadNaming.filename(suggested: long, url: nil, mimeType: nil)
        #expect(name.utf8.count <= DownloadNaming.maxBytes)
        #expect(name.hasSuffix(".zip"))
    }

    @Test func numbersNamesThatAreTaken() {
        let taken: Set = ["report.pdf", "report (2).pdf", "notes", "backup.tar.gz"]
        #expect(DownloadNaming.unique("new.pdf") { taken.contains($0) } == "new.pdf")
        #expect(DownloadNaming.unique("report.pdf") { taken.contains($0) } == "report (3).pdf")
        #expect(DownloadNaming.unique("notes") { taken.contains($0) } == "notes (2)")
        #expect(DownloadNaming.unique("backup.tar.gz") { taken.contains($0) } == "backup (2).tar.gz")
    }

    @Test func splitsOnlyRealExtensions() {
        #expect(DownloadNaming.split("version 1.2 notes") == ("version 1.2 notes", ""))
        #expect(DownloadNaming.split("a.b.c") == ("a.b", "c"))
        #expect(DownloadNaming.split("trailing.") == ("trailing.", ""))
    }
}
