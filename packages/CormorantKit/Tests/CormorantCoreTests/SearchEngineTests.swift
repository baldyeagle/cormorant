import Foundation
import Testing
@testable import CormorantCore

@Suite struct SearchEngineTests {
    @Test(arguments: [
        ("swift testing", "https://duckduckgo.com/?q=swift%20testing"),
        ("salt & pepper", "https://duckduckgo.com/?q=salt%20%26%20pepper"),
        ("c++", "https://duckduckgo.com/?q=c%2B%2B"),
        ("c# tips", "https://duckduckgo.com/?q=c%23%20tips"),
        ("a=b?", "https://duckduckgo.com/?q=a%3Db%3F"),
        ("café 日本", "https://duckduckgo.com/?q=caf%C3%A9%20%E6%97%A5%E6%9C%AC"),
        ("  padded  ", "https://duckduckgo.com/?q=padded"),
    ])
    func encodesQuery(query: String, expected: String) {
        #expect(SearchEngine.duckDuckGo.url(for: query)?.absoluteString == expected)
    }

    @Test func substitutesIntoEachBuiltInTemplate() {
        for engine in SearchEngine.builtIn {
            let result = engine.url(for: "hello world")
            #expect(result != nil, "\(engine.id)")
            #expect(result?.absoluteString.contains("hello%20world") == true, "\(engine.id)")
        }
    }

    @Test func emptyQueryIsNil() {
        #expect(SearchEngine.google.url(for: "") == nil)
        #expect(SearchEngine.google.url(for: "   \n") == nil)
    }

    @Test func badTemplateIsNil() {
        let noPlaceholder = SearchEngine(id: "x", name: "X", queryTemplate: "https://example.com/search")
        #expect(noPlaceholder.url(for: "q") == nil)
        let garbage = SearchEngine(id: "y", name: "Y", queryTemplate: "{query}")
        #expect(garbage.url(for: "q") == nil)
    }

    @Test func nonHTTPTemplatesAreUnusable() {
        for template in ["javascript:alert('{query}')", "JavaScript:void({query})", "data:text/html,{query}",
                         "file:///tmp/{query}", "ftp://example.com/?q={query}", "about:{query}", "https:///?q={query}"] {
            #expect(SearchEngine(id: "x", name: "X", queryTemplate: template).url(for: "q") == nil, "\(template)")
        }
        #expect(SearchEngine(id: "x", name: "X", queryTemplate: "http://search.local/?q={query}").url(for: "q") != nil)
        #expect(SearchEngine(id: "x", name: "X", queryTemplate: "HTTPS://Search.example/?q={query}").url(for: "q") != nil)
    }

    @Test func javascriptTemplateFallsBackToDefaultEngine() {
        let evil = SearchEngine(id: "evil", name: "Evil", queryTemplate: "javascript:fetch('//x/?{query}')")
        #expect(AddressResolver.resolve("tide pools", engine: evil)
            == .search(SearchEngine.default.url(for: "tide pools")!, query: "tide pools"))
    }
}

@Suite struct AddressResolverTests {
    enum Expected: Sendable, CustomStringConvertible {
        case navigate(String)
        case search
        case none

        var description: String {
            switch self {
            case .navigate(let s): "navigate(\(s))"
            case .search: "search"
            case .none: "nil"
            }
        }
    }

    static let cases: [(String, Expected)] = [
        // (a) explicit schemes
        ("https://example.com", .navigate("https://example.com")),
        ("http://example.com/a?b=c#d", .navigate("http://example.com/a?b=c#d")),
        ("HTTPS://Example.com/Path", .navigate("HTTPS://Example.com/Path")),
        ("about:blank", .navigate("about:blank")),
        ("  https://example.com  ", .navigate("https://example.com")),
        // (b) bare hosts
        ("example.com", .navigate("https://example.com")),
        ("Example.COM", .navigate("https://Example.COM")),
        ("www.example.co.uk/path/to?x=1", .navigate("https://www.example.co.uk/path/to?x=1")),
        ("foo.bar?x=1", .navigate("https://foo.bar?x=1")),
        ("example.com:8443/admin", .navigate("https://example.com:8443/admin")),
        ("my-host.example.dev#frag", .navigate("https://my-host.example.dev#frag")),
        ("printer.local", .navigate("https://printer.local")),
        ("localhost", .navigate("http://localhost")),
        ("localhost:3000", .navigate("http://localhost:3000")),
        ("localhost:3000/api/v1", .navigate("http://localhost:3000/api/v1")),
        ("192.168.1.1", .navigate("http://192.168.1.1")),
        ("10.0.0.2:8080/status", .navigate("http://10.0.0.2:8080/status")),
        ("example.com.", .navigate("https://example.com.")),
        ("example.com./path", .navigate("https://example.com./path")),
        ("[::1]:8080", .navigate("http://[::1]:8080")),
        ("[::1]", .navigate("http://[::1]")),
        ("[2001:db8::1]/status", .navigate("http://[2001:db8::1]/status")),
        ("example.com:65535", .navigate("https://example.com:65535")),
        ("docs.rs", .navigate("https://docs.rs")),
        ("claude.ai", .navigate("https://claude.ai")),
        ("www.example.md", .navigate("https://www.example.md")),
        ("example.md/page", .navigate("https://example.md/page")),
        ("bücher.de", .navigate("https://xn--bcher-kva.de")),
        ("пример.рф/путь", .navigate("https://xn--e1afmkfd.xn--p1ai/%D0%BF%D1%83%D1%82%D1%8C")),
        // (c) searches
        ("swift concurrency", .search),
        ("3.14", .search),
        ("v1.2", .search),
        ("1.2.3", .search),
        ("example.com/path with space", .search),
        ("hello", .search),
        ("e.g", .search),
        ("256.1.1.1", .search),
        ("localhost:99999", .search),
        ("example.com:abc", .search),
        ("-bad.com", .search),
        ("user@example.com", .search),
        ("mailto:me@example.com", .search),
        ("javascript:alert(1)", .search),
        ("https://", .search),
        ("what is example.com", .search),
        // Dotted words whose last label is not a TLD, or is far more often a file extension.
        ("node.js", .search),
        ("vue.js", .search),
        ("main.swift", .search),
        ("config.yaml", .search),
        ("README.md", .search),
        ("setup.py", .search),
        ("archive.zip", .search),
        ("example.notatld", .search),
        // Ports and IPv6 shapes that are not hosts.
        ("example.com:0", .search),
        ("example.com:65536", .search),
        ("localhost:0", .search),
        ("[::1", .search),
        ("[not-ipv6]:80", .search),
        ("[::1]:0", .search),
        ("[::1]x", .search),
        ("example.com..", .search),
        // Schemes the address bar does not open.
        ("file:///etc/passwd", .search),
        ("FILE:///etc/passwd", .search),
        ("data:text/html,<script>alert(1)</script>", .search),
        ("data:text/plain,hello", .search),
        // Unicode that does not form a valid hostname.
        ("日本.notatld", .search),
        ("☃", .search),
        // empty
        ("", .none),
        ("   ", .none),
    ]

    @Test(arguments: cases)
    func resolves(input: String, expected: Expected) {
        let result = AddressResolver.resolve(input, engine: .duckDuckGo)
        switch expected {
        case .navigate(let string):
            #expect(result == .navigate(URL(string: string)!))
        case .search:
            let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(result == .search(SearchEngine.duckDuckGo.url(for: query)!, query: query))
        case .none:
            #expect(result == nil)
        }
    }

    @Test func searchUsesGivenEngine() {
        let result = AddressResolver.resolve("tide pools", engine: .kagi)
        #expect(result == .search(URL(string: "https://kagi.com/search?q=tide%20pools")!, query: "tide pools"))
    }

    @Test func badEngineFallsBackToDefault() {
        let broken = SearchEngine(id: "broken", name: "Broken", queryTemplate: "nope")
        let result = AddressResolver.resolve("tide pools", engine: broken)
        #expect(result == .search(SearchEngine.default.url(for: "tide pools")!, query: "tide pools"))
    }
}
