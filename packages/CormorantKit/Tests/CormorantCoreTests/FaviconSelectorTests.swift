import Foundation
import Testing
@testable import CormorantCore

@Suite struct FaviconSelectorTests {
    let page = URL(string: "https://www.example.com/articles/1?x=y#top")!

    func candidate(_ href: String, rel: String = "icon", sizes: String? = nil, type: String? = nil) -> FaviconCandidate {
        FaviconCandidate(url: URL(string: href)!, rel: rel, sizes: sizes, type: type)
    }

    func best(_ candidates: [FaviconCandidate], page: URL? = nil) -> [String] {
        FaviconSelector.best(from: candidates, pageURL: page ?? self.page).map(\.absoluteString)
    }

    @Test func noCandidatesFallsBackToFaviconICO() {
        #expect(best([]) == ["https://www.example.com/favicon.ico"])
    }

    @Test func fallbackKeepsSchemeAndPortAndDropsCredentials() {
        let page = URL(string: "HTTP://user:pw@127.0.0.1:8080/a/b")!
        #expect(best([], page: page) == ["http://127.0.0.1:8080/favicon.ico"])
    }

    @Test func nonWebPageHasNothingToTry() {
        #expect(best([candidate("https://example.com/i.png")], page: URL(string: "about:blank")!).isEmpty)
        #expect(best([], page: URL(string: "file:///tmp/a.html")!).isEmpty)
    }

    @Test func touchIconsFirstThenLargeIconsThenUnsizedThenSmall() {
        let result = best([
            candidate("https://example.com/16.png", sizes: "16x16"),
            candidate("https://example.com/unsized.ico", rel: "shortcut icon"),
            candidate("https://example.com/32.png", sizes: "32x32"),
            candidate("https://example.com/192.png", sizes: "192x192"),
            candidate("https://example.com/touch-152.png", rel: "apple-touch-icon", sizes: "152x152"),
            candidate("https://example.com/touch.png", rel: "apple-touch-icon-precomposed"),
        ])
        #expect(result == [
            "https://example.com/touch.png",
            "https://example.com/touch-152.png",
            "https://example.com/192.png",
            "https://example.com/32.png",
            "https://example.com/unsized.ico",
            "https://example.com/16.png",
            "https://www.example.com/favicon.ico",
        ])
    }

    @Test func multipleSizesRankByLargest() {
        let result = best([
            candidate("https://example.com/a.ico", sizes: "16x16 48x48"),
            candidate("https://example.com/b.png", sizes: "40x40"),
        ])
        #expect(result.prefix(2) == ["https://example.com/a.ico", "https://example.com/b.png"])
    }

    @Test func anySizeRanksAsLarge() {
        let result = best([
            candidate("https://example.com/256.png", sizes: "256x256"),
            candidate("https://example.com/any.png", sizes: "any", type: "image/png"),
        ])
        #expect(result.first == "https://example.com/any.png")
    }

    @Test func tiesKeepDocumentOrder() {
        let result = best([
            candidate("https://example.com/first.png", sizes: "32x32"),
            candidate("https://example.com/second.png", sizes: "32x32"),
        ])
        #expect(result.prefix(2) == ["https://example.com/first.png", "https://example.com/second.png"])
    }

    @Test func skipsSVGByTypeOrExtension() {
        let result = best([
            candidate("https://example.com/icon", sizes: "any", type: "image/svg+xml"),
            candidate("https://example.com/icon.SVG"),
            candidate("https://example.com/icon.png", sizes: "32x32"),
        ])
        #expect(result == ["https://example.com/icon.png", "https://www.example.com/favicon.ico"])
    }

    @Test func skipsNonWebURLs() {
        let result = best([
            candidate("data:image/png;base64,AAAA"),
            candidate("ftp://example.com/icon.png"),
            candidate("javascript:alert(1)"),
        ])
        #expect(result == ["https://www.example.com/favicon.ico"])
    }

    @Test func ignoresRelsThatAreNotIcons() {
        let result = best([
            candidate("https://example.com/mask.svg", rel: "mask-icon"),
            candidate("https://example.com/fluid.png", rel: "fluid-icon"),
            candidate("https://example.com/style.css", rel: "stylesheet"),
            candidate("https://example.com/upper.png", rel: "ICON", sizes: "64x64"),
        ])
        #expect(result == ["https://example.com/upper.png", "https://www.example.com/favicon.ico"])
    }

    @Test func dedupesIncludingTheFallback() {
        let result = best([
            candidate("https://www.example.com/favicon.ico"),
            candidate("https://example.com/a.png", rel: "apple-touch-icon"),
            candidate("https://example.com/a.png", rel: "icon", sizes: "64x64"),
        ])
        #expect(result == ["https://example.com/a.png", "https://www.example.com/favicon.ico"])
    }

    @Test(arguments: [
        ("16x16", 16), ("32X32", 32), ("16x16 64x64 32x32", 64), ("120x60", 120), ("any", FaviconSelector.anySize),
        ("  48x48  ", 48),
    ])
    func parsesSizes(sizes: String, expected: Int) {
        #expect(FaviconSelector.largestSize(in: sizes) == expected)
    }

    @Test(arguments: ["", "big", "x32", "32x", "0x0", "-1x-1", "32x32x32"])
    func unparseableSizesAreUnknown(sizes: String) {
        #expect(FaviconSelector.largestSize(in: sizes) == nil)
    }

    @Test func malformedSizesRankAsUnsized() {
        let result = best([
            candidate("https://example.com/junk.png", sizes: "huge"),
            candidate("https://example.com/16.png", sizes: "16x16"),
        ])
        #expect(result.prefix(2) == ["https://example.com/junk.png", "https://example.com/16.png"])
    }

    @Test(arguments: [
        ("https://www.Example.com/a", "example.com"),
        ("https://example.com", "example.com"),
        ("https://mail.example.com/", "mail.example.com"),
        ("http://WWW.example.co.uk:8080/x", "http:example.co.uk"),
        ("https://www./", "www."),
        ("https://127.0.0.1:9000/", "127.0.0.1"),
        ("http://127.0.0.1:9000/", "http:127.0.0.1"),
    ])
    func hostKey(url: String, expected: String) {
        #expect(FaviconSelector.hostKey(for: URL(string: url)!) == expected)
    }

    @Test func hostKeyIsNilWithoutHost() {
        #expect(FaviconSelector.hostKey(for: URL(string: "about:blank")!) == nil)
        #expect(FaviconSelector.hostKey(for: URL(string: "file:///tmp/a")!) == nil)
    }

    @Test func fallbackStaysLastWhenAPageDeclaresIt() {
        let result = best([
            candidate("https://www.example.com/favicon.ico", sizes: "48x48"),
            candidate("https://example.com/a.png"),
        ])
        #expect(result == ["https://example.com/a.png", "https://www.example.com/favicon.ico"])
    }

    @Test func httpsPageSkipsPlainHTTPIcons() {
        let result = best([candidate("http://cdn.example.com/a.png", rel: "apple-touch-icon")])
        #expect(result == ["https://www.example.com/favicon.ico"])
        let plain = best([candidate("http://cdn.example.com/a.png")], page: URL(string: "http://example.com/")!)
        #expect(plain == ["http://cdn.example.com/a.png", "http://example.com/favicon.ico"])
    }

    @Test func keepsTheSiteAndItsSubdomainsOnly() {
        let result = best([
            candidate("https://static.example.com/a.png", rel: "apple-touch-icon"),
            candidate("https://example.com/b.png"),
            candidate("https://tracker.test/c.png", sizes: "512x512"),
            candidate("https://notexample.com/d.png"),
            candidate("https://com/e.png"),
        ])
        #expect(result == [
            "https://static.example.com/a.png", "https://example.com/b.png", "https://www.example.com/favicon.ico",
        ])
    }

    @Test func skipsLocalNetworkIconsFromOtherHosts() {
        let result = best([
            candidate("https://192.168.1.1/a.png"),
            candidate("https://localhost/b.png"),
            candidate("https://printer.local/c.png"),
            candidate("https://[::1]/d.png"),
        ])
        #expect(result == ["https://www.example.com/favicon.ico"])
    }

    @Test func aLocalPageKeepsItsOwnIcons() {
        let local = URL(string: "http://127.0.0.1:8080/")!
        let result = best([candidate("http://127.0.0.1:8080/a.png")], page: local)
        #expect(result == ["http://127.0.0.1:8080/a.png", "http://127.0.0.1:8080/favicon.ico"])
    }

    @Test(arguments: [
        "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.10", "169.254.1.1", "100.64.0.1",
        "0.0.0.0", "localhost", "router", "nas.local", "a.localhost", "box.home.arpa", "::1", "[::1]", "fd12::1",
        "fe80::1", "fec0::1", "::ffff:192.168.1.1", "[::ffff:c0a8:101]", "::ffff:7f00:1", "0:0:0:0:0:0:0:1",
        "64:ff9b::a00:1", "localhost.", "router.local.", "127.1", "0x7f.1", "2130706433", "",
    ])
    func localHosts(host: String) {
        #expect(FaviconSelector.isLocal(host: host))
    }

    @Test(arguments: [
        "example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700::1111", "64:ff9b::808:808",
        "github.githubassets.com", "cafe.be", "example.com.",
    ])
    func publicHosts(host: String) {
        #expect(!FaviconSelector.isLocal(host: host))
    }
}
