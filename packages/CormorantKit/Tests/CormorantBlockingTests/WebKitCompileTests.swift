import Foundation
import Testing
import WebKit
@testable import CormorantBlocking

@Suite("WebKit compiles converter output")
@MainActor
struct WebKitCompileTests {
    @Test func easyListExcerptCompiles() async throws {
        let text = try TestResources.easyListExcerpt()
        let conversion = ABPFilterConverter.convertPartitioned(text)
        let stats = conversion.statistics
        print("[excerpt] \(stats.summary) network=\(conversion.network.count) cosmetic=\(conversion.cosmetic.count)")
        #expect(stats.filterLines == 2_000)
        #expect(conversion.network.count > 500)
        #expect(conversion.cosmetic.count > 300)
        // Most of EasyList is expressible; a big drop means the converter regressed.
        #expect(stats.convertedLines > 1_800)

        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        #expect(await compiler.expectCompiles(conversion.network, "network") != nil)
        #expect(await compiler.expectCompiles(conversion.cosmetic, "cosmetic") != nil)
        let combined = ABPFilterConverter.convert(text)
        #expect(combined.rules.count > 0)
        #expect(await compiler.expectCompiles(combined.rules, "combined") != nil)
    }

    @Test func everySnippetFromTheUnitTestsCompiles() async throws {
        let text = """
        ||example.com^
        ||example.com^*/track.js
        |https://ads.
        /banner.gif|
        /ads^
        /ads^|
        &ad_type=^x
        /ad.php?id=(1)+[x]{y}\\
        /Ads.js$match-case
        ||ads.com^$third-party,script,image,stylesheet,object,xmlhttprequest,subdocument,font,media,websocket,ping,other
        ||ads.com^$~third-party,~script,~image
        ||ads.com^$popup
        ||ads.com^$document
        ||ads.com^$domain=a.com|~sub.a.com
        ||ads.com^$domain=~a.com
        $popup,domain=a.com
        /price=$/x
        /^https?:\\/\\/cdn\\.x\\.com\\/\\d+\\.js/$script
        /[a-z]+\\w\\.gif$/
        @@/complianz-gdpr-premium/cookiebanner/$script,~third-party
        *$ping,third-party
        ||0.0.0.0^$third-party,domain=~[::1]|~localhost
        ||ads.com^$domain=example.*|b.com
        example.*##.entity-ad
        @@||ads.com/allowed.js$script
        @@||example.com^$document
        @@||example.com^$generichide
        @@||example.com^$elemhide
        ##.ad-banner
        ###ad
        ##a[href^="http://ads.example.com/"]
        ##.md\\:flex
        example.com,foo.org##.sidebar-ad
        ~example.com##.ad
        ##.x
        example.com#@#.x
        """
        let conversion = ABPFilterConverter.convertPartitioned(text)
        #expect(conversion.statistics.skippedTotal == 0)
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        await compiler.expectCompiles(conversion.network, "network")
        await compiler.expectCompiles(conversion.cosmetic, "cosmetic")
    }

    /// The selector whitelist must only contain things WebKit accepts, or one rule breaks a whole list.
    @Test func pseudoClassWhitelistCompiles() async throws {
        let functional: [String: String] = [
            "not": "(.a)", "is": "(.a)", "where": "(.a)", "matches": "(.a)", "-webkit-any": "(.a)",
            "nth-child": "(2n+1)", "nth-last-child": "(2)", "nth-of-type": "(2)", "nth-last-of-type": "(2)",
            "lang": "(en)", "dir": "(ltr)", "state": "(x)", "host": "", "part": "(x)", "slotted": "(div)",
        ]
        var rules: [ContentRule] = []
        for name in ABPFilterConverter.supportedPseudoClasses.sorted() {
            rules.append(.hideRule("div:\(name)\(functional[name] ?? "")"))
        }
        for name in ABPFilterConverter.supportedPseudoElements.sorted() {
            rules.append(.hideRule("div::\(name)\(functional[name] ?? "")"))
        }
        rules.append(.hideRule("div:has(> .x)"))
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        await compiler.expectCompiles(rules, "pseudo whitelist")
    }

    @Test func emptyListIsRejectedByWebKit() async throws {
        // Why the engine never compiles empty chunks.
        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        await #expect(throws: (any Error).self) { try await compiler.compile([]) }
    }
}

/// Downloads ~5 MB of real lists; opt in with `CORMORANT_LIVE_TESTS=1 swift test`.
@Suite("Live filter lists", .enabled(if: ProcessInfo.processInfo.environment["CORMORANT_LIVE_TESTS"] == "1"),
       .timeLimit(.minutes(2)))
@MainActor
struct LiveFilterListTests {
    /// Fetches the real lists, converts, chunks and compiles them. Skipped (passes with a note) when offline.
    @Test func liveListsConvertAndCompile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)

        var texts: [(FilterListSource, String)] = []
        do {
            try await withThrowingTaskGroup(of: (FilterListSource, String).self) { group in
                for source in FilterListSource.allCases {
                    group.addTask {
                        let (data, response) = try await session.data(from: source.url)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        return (source, String(decoding: data, as: UTF8.self))
                    }
                }
                for try await result in group { texts.append(result) }
            }
        } catch {
            print("[live] skipped: could not fetch filter lists (\(error.localizedDescription))")
            return
        }
        texts.sort { $0.0.rawValue < $1.0.rawValue }

        let compiler = try WebKitCompiler()
        defer { compiler.cleanUp() }
        var totalRules = 0
        for (source, text) in texts {
            let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let convertStart = ContinuousClock.now
            let conversion = ABPFilterConverter.convertPartitioned(text)
            let convertTime = ContinuousClock.now - convertStart
            let chunks = ABPFilterConverter.chunk(conversion.network) + ABPFilterConverter.chunk(conversion.cosmetic)
            let stats = conversion.statistics

            let compileStart = ContinuousClock.now
            for (index, chunk) in chunks.enumerated() {
                await compiler.expectCompiles(chunk, "\(source.rawValue) chunk \(index)")
            }
            let compileTime = ContinuousClock.now - compileStart
            totalRules += conversion.network.count + conversion.cosmetic.count

            let options = stats.unsupportedOptions.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }
            print("""
            [live] \(source.rawValue): lines=\(lineCount) bytes=\(text.utf8.count) \
            rules=\(conversion.network.count + conversion.cosmetic.count) (network=\(conversion.network.count), \
            cosmetic=\(conversion.cosmetic.count)) chunks=\(chunks.count) convert=\(convertTime) compile=\(compileTime)
            [live]   \(stats.summary)
            [live]   unsupported options: \(options.joined(separator: ", "))
            """)
            #expect(conversion.network.count + conversion.cosmetic.count > 1_000)

            if source == .easyList {
                // The opt-in native `:has()` mode must also produce WebKit-valid lists.
                let withHas = ABPFilterConverter.convertPartitioned(text, options: .init(allowsNativeHas: true))
                for chunk in ABPFilterConverter.chunk(withHas.cosmetic) {
                    await compiler.expectCompiles(chunk, "easyList cosmetic with :has()")
                }
                print("[live]   with native :has(): cosmetic=\(withHas.cosmetic.count) (+\(withHas.cosmetic.count - conversion.cosmetic.count))")
            }
        }
        print("[live] total rules: \(totalRules)")
    }
}
