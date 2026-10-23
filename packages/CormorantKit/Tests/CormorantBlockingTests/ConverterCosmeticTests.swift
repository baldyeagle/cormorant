import Testing
@testable import CormorantBlocking

private func cosmetic(_ text: String, options: ABPFilterConverter.Options = .default) -> [ContentRule] {
    ABPFilterConverter.convertPartitioned(text, options: options).cosmetic
}

private func skipped(_ text: String) -> [ABPFilterConverter.SkipReason: Int] {
    ABPFilterConverter.convertPartitioned(text).statistics.skipped
}

@Suite("Converter: element hiding")
struct ConverterCosmeticTests {
    @Test func genericHideUsesMatchAllFilter() {
        #expect(cosmetic("##.ad-banner") == [.hideRule(".ad-banner")])
        #expect(cosmetic("###ad") == [.hideRule("#ad")])
        #expect(cosmetic("##a[href^=\"http://ads.example.com/\"]") == [.hideRule("a[href^=\"http://ads.example.com/\"]")])
        #expect(cosmetic(#"##.md\:flex"#) == [.hideRule(#".md\:flex"#)])
    }

    @Test func domainHideUsesIfDomain() {
        #expect(cosmetic("example.com,Foo.org##.sidebar-ad") == [.hideRule(".sidebar-ad", ifDomain: ["*example.com", "*foo.org"])])
    }

    @Test func negatedDomainsOnlyUseUnlessDomain() {
        #expect(cosmetic("~example.com,~b.org##.ad") == [.hideRule(".ad", unlessDomain: ["*example.com", "*b.org"])])
    }

    @Test func mixedDomainsKeepIncludesOnly() {
        #expect(cosmetic("example.com,~sub.example.com##.ad") == [.hideRule(".ad", ifDomain: ["*example.com"])])
    }

    @Test func entityWildcardDomainsAreExpanded() throws {
        let rules = cosmetic("example.*,b.com##.ad")
        #expect(rules.count == 1)
        let ifDomain = try #require(rules.first?.trigger.ifDomain)
        #expect(ifDomain.first == "*example.com")
        #expect(ifDomain.contains("*example.co.uk"))
        #expect(ifDomain.last == "*b.com")
        #expect(skipped("ex*ample.com##.ad") == [.unsupportedDomain: 1])
    }

    @Test func hideExceptionsAddUnlessDomainToGenericRules() {
        let conversion = ABPFilterConverter.convertPartitioned("##.ad\nexample.com#@#.ad\nfoo.org#@#.ad")
        #expect(conversion.cosmetic == [.hideRule(".ad", unlessDomain: ["*example.com", "*foo.org"])])
        #expect(conversion.statistics.skippedTotal == 0)
    }

    @Test func hideExceptionsRemoveDomainsFromSpecificRules() {
        #expect(cosmetic("example.com,b.com##.x\nexample.com#@#.x") == [.hideRule(".x", ifDomain: ["*b.com"])])
        #expect(cosmetic("sub.example.com##.x\nexample.com#@#.x").isEmpty)
    }

    /// `sub.example.com#@#.ad` cannot be expressed against `example.com##.ad` (WebKit forbids if-domain
    /// with unless-domain), so it is counted as skipped rather than claimed as applied.
    @Test func subdomainExceptionToADomainHideIsCountedAsSkipped() {
        let conversion = ABPFilterConverter.convertPartitioned("example.com##.ad\nsub.example.com#@#.ad")
        #expect(conversion.cosmetic == [.hideRule(".ad", ifDomain: ["*example.com"])])
        #expect(conversion.statistics.skipped == [.cosmeticException: 1])

        // Applied to the generic rule, but still inexpressible for the domain one: counted once.
        let mixed = ABPFilterConverter.convertPartitioned("##.ad\nexample.com##.ad\nsub.example.com#@#.ad")
        #expect(mixed.cosmetic == [
            .hideRule(".ad", unlessDomain: ["*sub.example.com"]),
            .hideRule(".ad", ifDomain: ["*example.com"]),
        ])
        #expect(mixed.statistics.skipped == [.cosmeticException: 1])
    }

    @Test func exceptionForAnUnrelatedDomainIsNotClaimed() {
        let conversion = ABPFilterConverter.convertPartitioned("example.com##.x\nfoo.org#@#.x")
        #expect(conversion.cosmetic == [.hideRule(".x", ifDomain: ["*example.com"])])
        #expect(conversion.statistics.skipped == [.cosmeticException: 1])
    }

    @Test func globalHideExceptionRemovesTheRule() {
        #expect(cosmetic("##.x\nexample.com##.x\n#@#.x").isEmpty)
    }

    @Test func unmatchedHideExceptionsAreCounted() {
        #expect(skipped("example.com#@#.not-here") == [.cosmeticException: 1])
        #expect(skipped("~example.com#@#.x") == [.cosmeticException: 1])
    }

    @Test(arguments: [
        ("example.com#?#div:-abp-has(.ad)", ABPFilterConverter.SkipReason.extendedCSS),
        ("##div:-abp-contains(Sponsored)", .extendedCSS),
        ("##div:has-text(Sponsored)", .extendedCSS),
        ("##div:contains(Sponsored)", .extendedCSS),
        ("##div:xpath(//div)", .extendedCSS),
        ("##div:matches-css(position: fixed)", .extendedCSS),
        ("##.ad:upward(2)", .extendedCSS),
        ("##.ad:remove()", .extendedCSS),
        ("##div:has(> .ad)", .extendedCSS),
        ("example.com#@?#div:-abp-has(.ad)", .cosmeticException),
        ("example.com#$#abort-on-property-read adsbygoogle", .scriptlet),
        ("example.com#%#//scriptlet('abort-on-property-read', 'x')", .scriptlet),
        ("example.com#@%#//scriptlet('x')", .cosmeticException),
        ("example.com##+js(nobab)", .scriptlet),
        ("example.com##^script:has-text(ads)", .htmlFilter),
        ("example.com$$script[tag-content=\"ads\"]", .htmlFilter),
        ("##.a[[b]", .invalidSelector),
        ("##.ad { color: red }", .cssInjection),
        ("example.com##body {overflow:auto;}", .cssInjection),
        ("##div:bogus", .invalidSelector),
        ("##div::bogus", .invalidSelector),
        ("##div[a=\"unterminated]", .invalidSelector),
        ("##div:not(.a", .invalidSelector),
        ("example.com##", .malformed),
    ])
    func unsupportedCosmeticsAreSkipped(filter: String, reason: ABPFilterConverter.SkipReason) {
        let conversion = ABPFilterConverter.convertPartitioned(filter)
        #expect(conversion.cosmetic.isEmpty)
        #expect(conversion.network.isEmpty)
        #expect(conversion.statistics.skipped == [reason: 1])
    }

    @Test func nativeHasCanBeEnabled() {
        let options = ABPFilterConverter.Options(allowsNativeHas: true)
        #expect(cosmetic("##div:has(> .ad)", options: options) == [.hideRule("div:has(> .ad)")])
        #expect(cosmetic("##aside:not(:has(video))", options: options) == [.hideRule("aside:not(:has(video))")])
    }

    @Test func standardPseudoClassesAreKept() {
        for selector in ["div:not(.a)", "li:nth-child(2n+1)", "div:first-child", "a:is(.x, .y)", "div::before", "div:empty"] {
            #expect(cosmetic("##" + selector) == [.hideRule(selector)], "\(selector)")
        }
    }
}

@Suite("Chunking")
struct ChunkTests {
    private func block(_ n: Int) -> ContentRule { .blockRule("b\(n)") }
    private func exception(_ n: Int) -> ContentRule { .exceptionRule("e\(n)") }

    @Test func plainSplitKeepsOrder() {
        let rules = (0..<5).map(block)
        #expect(ABPFilterConverter.chunk(rules, maxPerList: 2) == [[block(0), block(1)], [block(2), block(3)], [block(4)]])
        #expect(ABPFilterConverter.chunk(rules) == [rules])
        #expect(ABPFilterConverter.chunk([]) == [])
    }

    @Test func trailingExceptionsAreDuplicatedIntoEveryChunk() {
        let rules = (0..<5).map(block) + [exception(0), exception(1)]
        let chunks = ABPFilterConverter.chunk(rules, maxPerList: 4)
        #expect(chunks == [
            [block(0), block(1), exception(0), exception(1)],
            [block(2), block(3), exception(0), exception(1)],
            [block(4), exception(0), exception(1)],
        ])
        #expect(chunks.allSatisfy { $0.count <= 4 })
    }

    @Test func interleavedExceptionsKeepTheirRelativePosition() {
        let rules = [block(0), block(1), exception(0), block(2), block(3), exception(1)]
        #expect(ABPFilterConverter.chunk(rules, maxPerList: 4) == [
            [block(0), block(1), exception(0), exception(1)],
            [block(2), block(3), exception(1)],
        ])
        #expect(ABPFilterConverter.chunk(rules) == [rules])
    }

    @Test func leadingExceptionsAreNoOpsAndDropped() {
        #expect(ABPFilterConverter.chunk([exception(0), block(0)]) == [[block(0)]])
        #expect(ABPFilterConverter.chunk([exception(0), exception(1)]) == [])
    }

    @Test func tooManyExceptionsFallsBackToPlainSplit() {
        let rules = [block(0), block(1)] + (0..<4).map(exception)
        let chunks = ABPFilterConverter.chunk(rules, maxPerList: 3)
        #expect(chunks == [[block(0), block(1), exception(0)], [exception(1), exception(2), exception(3)]])
    }

    @Test func largeChunkingRespectsLimitAndCoversEveryBlock() {
        let blocks = (0..<10_000).map(block)
        let exceptions = (0..<50).map(exception)
        let chunks = ABPFilterConverter.chunk(blocks + exceptions, maxPerList: 1_000)
        #expect(chunks.allSatisfy { $0.count <= 1_000 && Array($0.suffix(50)) == exceptions })
        #expect(chunks.flatMap { $0.dropLast(50) } == blocks)
    }
}
