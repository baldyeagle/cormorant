import Foundation
import Testing
@testable import CormorantCore

@Suite struct PageFileTests {
    private let chart = URL(string: "https://aeronav.faa.gov/visual/10-29-2026/PDFs/Seattle.pdf")!

    @Test func aPDFIsAFile() throws {
        let file = try #require(PageFile(url: chart, mimeType: "application/pdf", suggestedFilename: "Seattle.pdf"))
        #expect(file.filename == "Seattle.pdf")
        #expect(file.mimeType == "application/pdf")
        #expect(file.url == chart)
    }

    @Test func imagesAndTextAreFiles() {
        let url = URL(string: "https://example.com/a")!
        for type in ["image/png", "text/plain; charset=utf-8", "application/json", "IMAGE/SVG+XML"] {
            #expect(PageFile(url: url, mimeType: type, suggestedFilename: nil) != nil, "\(type)")
        }
    }

    @Test func typeIsNormalized() {
        let file = PageFile(url: URL(string: "https://example.com/notes")!, mimeType: "Text/Plain; charset=utf-8", suggestedFilename: nil)
        #expect(file?.mimeType == "text/plain")
    }

    @Test func webPagesAreNot() {
        for type in ["text/html", "text/html; charset=utf-8", "application/xhtml+xml", "multipart/x-mixed-replace; boundary=x"] {
            #expect(PageFile(url: chart, mimeType: type, suggestedFilename: "Seattle.pdf") == nil, "\(type)")
        }
    }

    /// A stream (a radio station) would never finish fetching.
    @Test func audioAndVideoAreNot() {
        let url = URL(string: "https://example.com/live")!
        for type in ["audio/mpeg", "video/mp4", "Video/MP2T"] {
            #expect(PageFile(url: url, mimeType: type, suggestedFilename: nil) == nil, "\(type)")
        }
    }

    @Test func noTypeIsNot() {
        #expect(PageFile(url: chart, mimeType: nil, suggestedFilename: "Seattle.pdf") == nil)
        #expect(PageFile(url: chart, mimeType: "", suggestedFilename: "Seattle.pdf") == nil)
    }
}

@Suite struct PageFileVersionTests {
    @Test func etagComesFirst() {
        #expect(PageFile.version(etag: "\"2b2d\"", lastModified: "Thu, 29 Oct 2026 00:00:00 GMT") == "etag:\"2b2d\"")
        #expect(PageFile.version(etag: nil, lastModified: "Thu, 29 Oct 2026 00:00:00 GMT") == "modified:Thu, 29 Oct 2026 00:00:00 GMT")
        #expect(PageFile.version(etag: "", lastModified: nil) == nil)
    }

    @Test func anUnknownLengthIsNil() {
        let url = URL(string: "https://example.com/a.pdf")!
        #expect(PageFile(url: url, mimeType: "application/pdf", suggestedFilename: nil, expectedLength: -1)?.expectedLength == nil)
        #expect(PageFile(url: url, mimeType: "application/pdf", suggestedFilename: nil, expectedLength: 183_376_916)?.expectedLength == 183_376_916)
    }
}

@Suite struct TransferTextTests {
    private let us = Locale(identifier: "en_US")

    @Test func countsUpToTheSize() {
        #expect(TransferText.line(received: 42_100_000, expected: 183_376_916, locale: us) == "42.1 MB of 183.4 MB")
    }

    @Test func beforeAnythingArrives() {
        #expect(TransferText.line(received: 0, expected: nil, locale: us) == "Starting…")
        #expect(TransferText.line(received: 0, expected: 183_376_916, locale: us) == "Starting…")
    }

    @Test func noSizeJustCounts() {
        #expect(TransferText.line(received: 10_500_000, expected: nil, locale: us) == "10.5 MB")
        #expect(TransferText.fraction(received: 10, expected: nil) == nil)
    }

    @Test func fractionStaysInBounds() {
        #expect(TransferText.fraction(received: 50, expected: 200) == 0.25)
        #expect(TransferText.fraction(received: 300, expected: 200) == 1)
    }
}
