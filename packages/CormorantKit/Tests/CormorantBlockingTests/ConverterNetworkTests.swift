import Foundation
import Testing
@testable import CormorantBlocking

private let host = #"^[^:]+:(//)?([^/]+\.)?"#
private let sep = "[^a-zA-Z0-9_.%-]"

/// The rule matching the fully qualified form of a `||host` rule's host (`example.com.`), computed
/// independently of the converter: `\.` inserted where the escaped host name ends.
func fullyQualifiedTwin(of rule: ContentRule) -> ContentRule? {
    let filter = rule.trigger.urlFilter
    guard filter.hasPrefix(host) else { return nil }
    var index = filter.index(filter.startIndex, offsetBy: host.count)
    while index < filter.endIndex {
        let character = filter[index]
        if character == "\\", filter[index...].hasPrefix("\\.") {
            index = filter.index(index, offsetBy: 2)
        } else if character.isLetter || character.isNumber || character == "-" || character == "_" {
            index = filter.index(after: index)
        } else {
            break
        }
    }
    guard index < filter.endIndex, "[/:".contains(filter[index]) else { return nil }
    var twin = rule
    twin.trigger.urlFilter.insert(contentsOf: #"\."#, at: index)
    return twin
}

/// Drops fully qualified twins, checking each one immediately follows its rule and is exact.
private func withoutTwins(_ rules: [ContentRule], sourceLocation: SourceLocation = #_sourceLocation) -> [ContentRule] {
    var result: [ContentRule] = []
    var index = 0
    while index < rules.count {
        let rule = rules[index]
        result.append(rule)
        if let twin = fullyQualifiedTwin(of: rule) {
            #expect(index + 1 < rules.count && rules[index + 1] == twin, "missing twin for \(rule)", sourceLocation: sourceLocation)
            index += 2
        } else {
            index += 1
        }
    }
    return result
}

/// Network rules without the fully qualified twins (which are verified).
private func network(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> [ContentRule] {
    withoutTwins(ABPFilterConverter.convertPartitioned(text).network, sourceLocation: sourceLocation)
}

private func only(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> ContentRule? {
    let rules = withoutTwins(ABPFilterConverter.convert(text).rules, sourceLocation: sourceLocation)
    #expect(rules.count == 1, "expected exactly one rule for \(text), got \(rules)", sourceLocation: sourceLocation)
    return rules.first
}

private func skipped(_ text: String) -> [ABPFilterConverter.SkipReason: Int] {
    ABPFilterConverter.convertPartitioned(text).statistics.skipped
}

@Suite("Converter: comments and headers")
struct ConverterBasicsTests {
    @Test func commentsHeadersAndBlankLinesAreIgnoredNotSkipped() {
        let text = "[Adblock Plus 2.0]\n! Title: EasyList\n\n   \n! comment ||ads.com^\n# hosts-style comment\r\n"
        let conversion = ABPFilterConverter.convertPartitioned(text)
        #expect(conversion.network.isEmpty)
        #expect(conversion.cosmetic.isEmpty)
        #expect(conversion.statistics.skippedTotal == 0)
        #expect(conversion.statistics.ignoredLines == 6)
        #expect(ABPFilterConverter.convert(text) == ConversionResult(rules: [], skippedLines: 0))
    }

    @Test func crlfAndTrailingWhitespaceAreTrimmed() {
        #expect(only("||ads.com^  \r") == .blockRule(host + #"ads\.com[/:]"#))
    }
}

@Suite("Converter: network patterns")
struct ConverterPatternTests {
    @Test func domainAnchor() {
        #expect(only("||example.com^") == .blockRule(host + #"example\.com[/:]"#))
    }

    @Test func domainAnchorWithPath() {
        #expect(only("||example.com/ads/") == .blockRule(host + #"example\.com/ads/"#))
        #expect(only("||example.com^*/track.js") == .blockRule(host + #"example\.com[/:].*/track\.js"#))
    }

    @Test func startAndEndAnchors() {
        #expect(only("|https://ads.") == .blockRule(#"^https://ads\."#))
        #expect(only("/banner.gif|") == .blockRule(#"/banner\.gif$"#))
        #expect(only("|http://x.com/a.js|") == .blockRule(#"^http://x\.com/a\.js$"#))
    }

    @Test func wildcards() {
        #expect(only("/ads/*/track") == .blockRule("/ads/.*/track"))
        #expect(only("*/ads/**") == .blockRule("/ads/"))
        #expect(only("/a**b") == .blockRule("/a.*b"))
    }

    @Test func separators() {
        #expect(only("&ad_type=^x") == .blockRule("&ad_type=\(sep)x"))
        #expect(only("/ads^") == .blockRule("/ads(\(sep).*)?$"))
        #expect(only("/ads^|") == .blockRule("/ads\(sep)?$"))
    }

    @Test func metacharactersAreEscaped() {
        #expect(only("/ad.php?id=(1)+[x]{y}\\") == .blockRule(#"/ad\.php\?id=\(1\)\+\[x\]\{y\}\\"#))
        #expect(only("/a|b") == .blockRule(#"/a\|b"#))
    }

    @Test func patternsAreLowercasedUnlessMatchCase() {
        #expect(only("||Example.COM/Ads") == .blockRule(host + #"example\.com/ads"#))
        #expect(only("/Ads.js$match-case") == .blockRule(#"/Ads\.js"#, caseSensitive: true))
    }

    @Test func regexFiltersWebKitCannotExpressAreSkipped() {
        #expect(skipped(#"/^https?:\/\/[a-z]{8}\.com\//$script"#) == [.regexFilter: 1])
        #expect(skipped(#"/(https?:\/\/)104\.154\..{100,}/"#) == [.regexFilter: 1])
        #expect(skipped("/ads|banners/") == [.regexFilter: 1])
        #expect(skipped("/ad(?=s)/") == [.regexFilter: 1])
        #expect(skipped(#"/ad\sbanner/"#) == [.regexFilter: 1])
        #expect(skipped("/a^b/") == [.regexFilter: 1])
    }

    /// Shapes WebKit (or ICU) rejects; one of them in a list makes WebKit reject the whole list.
    @Test(arguments: [
        "/(ads/", "/ads)/", "/(a(b)/", "/[ads/", "/ads]/", "/a]b[/",
        "/*ads/", "/+ads/", "/?ads/", "/^*ads/",
        "/ads**/", "/ads+*/", "/ads??/", "/ads*?/", "/ads++/",
        "/(*ads)/", "/a(+b)/", "/a(?b)/", "/()/",
        "/[z-a]/", "/[[a]/",
    ])
    func malformedRegexFiltersAreSkipped(filter: String) {
        let conversion = ABPFilterConverter.convertPartitioned(filter)
        #expect(conversion.statistics.skipped == [.regexFilter: 1], "\(filter)")
        #expect(conversion.network.isEmpty)
    }

    @Test func simpleRegexFiltersAreKept() {
        #expect(only(#"/^https?:\/\/cdn\.x\.com\/\d+\.js/$script"#)
            == .blockRule(#"^https?://cdn\.x\.com/[0-9]+\.js"#, types: ["script"]))
        #expect(only("/ad$/") == .blockRule("ad$"))
        #expect(only("/ad(s)?\\.js/") == .blockRule(#"ad(s)?\.js"#))
        #expect(only("/[*+?]x+/") == .blockRule("[*+?]x+"))
        #expect(only(#"/[\/.]ads[0-9]*\//"#) == .blockRule("[/.]ads[0-9]*/"))
        #expect(only(#"/[a-z]+\w\.gif$/"#) == .blockRule(#"[a-z]+[a-zA-Z0-9_]\.gif$"#))
        // Looks like a regex but is a plain path in practice (EasyList Cookie).
        #expect(network("/cookiebanner/*\n@@/complianz-gdpr-premium/cookiebanner/$script,~third-party").last
            == .exceptionRule("complianz-gdpr-premium/cookiebanner", types: ["script"], load: ["first-party"]))
    }

    @Test func nonASCIIPatternsAreSkipped() {
        #expect(skipped("||пример.рф^") == [.nonASCIIPattern: 1])
    }

    @Test func patternsMatchingEverythingNeedADomain() {
        #expect(skipped("*$third-party") == [.tooBroad: 1])
        #expect(skipped("$script") == [.tooBroad: 1])
        // Blocking every third-party beacon is deliberate (EasyPrivacy) and never breaks pages.
        #expect(only("*$ping,third-party") == .blockRule(".*", types: ["ping"], load: ["third-party"]))
        #expect(only("$popup,domain=a.com") == .blockRule(".*", types: ["popup"], ifDomain: ["*a.com"]))
        #expect(only("*$script,domain=a.com") == .blockRule(".*", types: ["script"], ifDomain: ["*a.com"]))
    }
}

@Suite("Converter: options")
struct ConverterOptionTests {
    @Test func thirdParty() {
        #expect(only("||ads.com^$third-party") == .blockRule(host + #"ads\.com[/:]"#, load: ["third-party"]))
        #expect(only("||ads.com^$~third-party") == .blockRule(host + #"ads\.com[/:]"#, load: ["first-party"]))
        #expect(only("||ads.com^$3p") == .blockRule(host + #"ads\.com[/:]"#, load: ["third-party"]))
        #expect(only("||ads.com^$1p") == .blockRule(host + #"ads\.com[/:]"#, load: ["first-party"]))
    }

    @Test func resourceTypes() {
        #expect(only("||ads.com^$script,image") == .blockRule(host + #"ads\.com[/:]"#, types: ["image", "script"]))
        #expect(only("||ads.com^$stylesheet") == .blockRule(host + #"ads\.com[/:]"#, types: ["style-sheet"]))
        #expect(only("||ads.com^$xmlhttprequest,subdocument,object,font,media,websocket,ping,other")
            == .blockRule(host + #"ads\.com[/:]"#, types: ["document", "font", "media", "ping", "fetch", "websocket", "other"]))
        #expect(only("||ads.com^$popup") == .blockRule(host + #"ads\.com[/:]"#, types: ["popup"]))
        #expect(only("||ads.com^$document") == .blockRule(host + #"ads\.com[/:]"#, types: ["document"]))
        #expect(only("||ads.com^$xhr,css,frame") == .blockRule(host + #"ads\.com[/:]"#, types: ["document", "style-sheet", "fetch"]))
    }

    @Test func negatedResourceTypesUseTheComplement() {
        #expect(only("||ads.com^$~script,~image")
            == .blockRule(host + #"ads\.com[/:]"#, types: ["document", "style-sheet", "font", "media", "ping", "fetch", "websocket", "other"]))
        #expect(only("||ads.com^$~xmlhttprequest,~subdocument,~object,~other")
            == .blockRule(host + #"ads\.com[/:]"#, types: ["image", "style-sheet", "script", "font", "media", "ping", "websocket"]))
    }

    @Test func importantAndAllAreNormalBlocks() {
        #expect(only("||ads.com^$important") == .blockRule(host + #"ads\.com[/:]"#))
        #expect(only("||ads.com^$all") == .blockRule(host + #"ads\.com[/:]"#))
    }

    @Test func combinedOptions() {
        #expect(only("||ads.com/x.js$script,third-party,domain=a.com|b.org")
            == .blockRule(host + #"ads\.com/x\.js"#, types: ["script"], load: ["third-party"], ifDomain: ["*a.com", "*b.org"]))
    }

    @Test func domainOption() {
        #expect(only("||ads.com^$domain=A.com|b.com") == .blockRule(host + #"ads\.com[/:]"#, ifDomain: ["*a.com", "*b.com"]))
        #expect(only("||ads.com^$domain=~a.com|~b.com") == .blockRule(host + #"ads\.com[/:]"#, unlessDomain: ["*a.com", "*b.com"]))
    }

    @Test func mixedDomainsBecomeABlockPlusACarveOutException() {
        let filter = host + #"ads\.com[/:]"#
        #expect(network("||ads.com^$script,domain=a.com|~sub.a.com|~other.com") == [
            .blockRule(filter, types: ["script"], ifDomain: ["*a.com"]),
            .exceptionRule(filter, types: ["script"], ifDomain: ["*sub.a.com"]),
        ])
        // Excludes outside the included domains are irrelevant and dropped.
        #expect(network("||ads.com^$domain=a.com|~other.com") == [.blockRule(filter, ifDomain: ["*a.com"])])
    }

    /// Reviewer reproduction: the `~sub.a.com` carve-out must not also cancel the unrelated generic
    /// `||ads.com^$script`, so ads.com scripts stay blocked on sub.a.com.
    @Test(arguments: [
        "||ads.com^$script\n||ads.com^$script,domain=a.com|~sub.a.com",
        "||ads.com^$script,domain=a.com|~sub.a.com\n||ads.com^$script",
    ])
    func carveOutsDoNotCancelGenericRulesWithTheSameFilter(text: String) throws {
        let rules = ABPFilterConverter.convertPartitioned(text).network
        func blocked(on page: String, maxPerList: Int = 150_000) throws -> Bool {
            let request = RuleEvaluator.Request(url: "https://ads.com/x.js", resourceType: "script", pageHost: page)
            return try RuleEvaluator.isBlocked(request, lists: ABPFilterConverter.chunk(rules, maxPerList: maxPerList))
        }
        #expect(try blocked(on: "sub.a.com"))
        #expect(try blocked(on: "a.com"))
        #expect(try blocked(on: "other.com"))
        // Still true when chunking splits the carve-out pair from the generic rule.
        #expect(try blocked(on: "sub.a.com", maxPerList: 3))
    }

    @Test func carveOutStillExemptsTheSubdomainAndExceptionsStillApply() throws {
        let rules = ABPFilterConverter.convertPartitioned(
            "||ads.com^$script,domain=a.com|~sub.a.com\n||tracker.net^\n@@||ads.com/ok.js$script").network
        func blocked(_ url: String, on page: String) throws -> Bool {
            try RuleEvaluator.isBlocked(.init(url: url, resourceType: "script", pageHost: page), by: rules)
        }
        #expect(try blocked("https://ads.com/x.js", on: "a.com"))
        #expect(try blocked("https://ads.com/x.js", on: "www.a.com"))
        #expect(try !blocked("https://ads.com/x.js", on: "sub.a.com"))
        #expect(try !blocked("https://ads.com/x.js", on: "deep.sub.a.com"))
        #expect(try !blocked("https://ads.com/x.js", on: "b.com"))
        #expect(try !blocked("https://ads.com/ok.js", on: "a.com"))
        #expect(try blocked("https://tracker.net/t.js", on: "sub.a.com"))
        // Fully qualified hosts behave the same.
        #expect(try blocked("https://ads.com./x.js", on: "a.com"))
        #expect(try !blocked("https://ads.com./x.js", on: "sub.a.com"))
        #expect(try !blocked("https://ads.com./ok.js", on: "a.com"))
        // Carve-out pairs lead the list, ahead of the generic blocks.
        #expect(withoutTwins(rules).map(\.action.type) == ["block", "ignore-previous-rules", "block", "ignore-previous-rules"])
    }

    @Test func unrepresentableDomains() {
        #expect(skipped("||ads.com^$domain=пример.рф") == [.unsupportedDomain: 1])
        #expect(skipped("||ads.com^$domain=~ex*ample.com") == [.unsupportedDomain: 1])
        #expect(only("||ads.com^$domain=пример.рф|b.com") == .blockRule(host + #"ads\.com[/:]"#, ifDomain: ["*b.com"]))
        // IPv6 literals are ignored.
        #expect(only("||0.0.0.0^$third-party,domain=~[::1]|~localhost")
            == .blockRule(host + #"0\.0\.0\.0[/:]"#, load: ["third-party"], unlessDomain: ["*localhost"]))
    }

    @Test func entityDomainsExpandToCommonSuffixes() throws {
        let rule = try #require(only("||ads.com^$domain=example.*|b.com"))
        let ifDomain = try #require(rule.trigger.ifDomain)
        #expect(ifDomain.count == ABPFilterConverter.entitySuffixes.count + 1)
        #expect(ifDomain.contains("*example.com"))
        #expect(ifDomain.contains("*example.co.uk"))
        #expect(ifDomain.contains("*example.de"))
        #expect(ifDomain.last == "*b.com")
        #expect(try #require(only("||ads.com^$domain=~google.*")).trigger.unlessDomain?.contains("*google.fr") == true)
    }

    @Test(arguments: [
        ("||a.com^$csp=script-src 'none'", "csp"),
        ("||a.com^$redirect=noopjs", "redirect"),
        ("||a.com^$redirect-rule=noopjs", "redirect-rule"),
        ("||a.com^$removeparam=utm_source", "removeparam"),
        ("||a.com^$rewrite=abp-resource:blank-js", "rewrite"),
        ("||a.com^$replace=/a/b/", "replace"),
        ("||a.com^$header=via:1.1 google", "header"),
        ("||a.com^$cookie=foo", "cookie"),
        ("||a.com^$badfilter", "badfilter"),
        ("*$script,denyallow=b.com,domain=a.com", "denyallow"),
        ("||a.com^$inline-script", "inline-script"),
        ("||a.com^$empty", "empty"),
        ("||a.com^$mp4", "mp4"),
        ("||a.com^$method=post", "method"),
        ("||a.com^$genericblock", "genericblock"),
        ("||a.com^$webrtc", "webrtc"),
    ])
    func unsupportedOptionsAreSkipped(filter: String, option: String) {
        let stats = ABPFilterConverter.convertPartitioned(filter).statistics
        #expect(stats.skipped == [.unsupportedOption: 1])
        #expect(stats.unsupportedOptions == [option: 1])
        #expect(ABPFilterConverter.convert(filter).rules.isEmpty)
    }

    @Test func dollarInsidePatternWithoutOptionsIsLiteral() {
        #expect(only("/price=$/x") == .blockRule(#"/price=\$/x"#))
    }
}

@Suite("Converter: exceptions")
struct ConverterExceptionTests {
    @Test func exceptionsBecomeIgnorePreviousRules() {
        #expect(network("||ads.com^\n@@||ads.com/allowed.js$script") == [
            .blockRule(host + #"ads\.com[/:]"#),
            .exceptionRule(host + #"ads\.com/allowed\.js"#, types: ["script"]),
        ])
    }

    @Test func exceptionsComeAfterAllBlocksRegardlessOfSourceOrder() {
        #expect(network("@@||ads.com/ok$image\n||ads.com^\n||tracker.net^") == [
            .blockRule(host + #"ads\.com[/:]"#),
            .blockRule(host + #"tracker\.net[/:]"#),
            .exceptionRule(host + #"ads\.com/ok"#, types: ["image"]),
        ])
    }

    @Test func documentExceptionAllowlistsTheWholeSite() {
        let conversion = ABPFilterConverter.convertPartitioned("||ads.com^\n##.ad\n@@||example.com^$document")
        let allowSite = ContentRule.exceptionRule(".*", ifDomain: ["*example.com"])
        #expect(withoutTwins(conversion.network) == [.blockRule(host + #"ads\.com[/:]"#), allowSite])
        #expect(conversion.cosmetic == [.hideRule(".ad"), allowSite])
    }

    @Test func genericHideExceptionSitsBetweenGenericAndSpecificHides() {
        let conversion = ABPFilterConverter.convertPartitioned("example.com##.own-ad\n##.ad\n@@||example.com^$generichide")
        #expect(conversion.cosmetic == [
            .hideRule(".ad"),
            .exceptionRule(".*", ifDomain: ["*example.com"]),
            .hideRule(".own-ad", ifDomain: ["*example.com"]),
        ])
        #expect(conversion.network.isEmpty)
    }

    @Test func elemHideExceptionComesAfterAllHides() {
        let conversion = ABPFilterConverter.convertPartitioned("example.com##.own-ad\n##.ad\n@@||example.com^$elemhide")
        #expect(conversion.cosmetic == [
            .hideRule(".ad"),
            .hideRule(".own-ad", ifDomain: ["*example.com"]),
            .exceptionRule(".*", ifDomain: ["*example.com"]),
        ])
    }

    @Test func pageExceptionsOnComplexPatternsAreSkipped() {
        #expect(skipped("@@||example.com/path/*.html$generichide") == [.unsupportedException: 1])
    }

    @Test func combinedOutputPutsCosmeticBeforeNetwork() {
        let rules = withoutTwins(ABPFilterConverter.convert("||ads.com^\n##.ad\n@@||ads.com/ok$image").rules)
        #expect(rules == [
            .hideRule(".ad"),
            .blockRule(host + #"ads\.com[/:]"#),
            .exceptionRule(host + #"ads\.com/ok"#, types: ["image"]),
        ])
    }
}

@Suite("Converter: regex semantics")
struct ConverterRegexSemanticsTests {
    private func matches(_ filter: String, _ url: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test func domainAnchorMatchesTheDomainAndSubdomainsOnly() throws {
        let filter = try #require(only("||example.com^")).trigger.urlFilter
        #expect(try matches(filter, "https://sub.example.com/x"))
        #expect(try matches(filter, "http://example.com/"))
        #expect(try matches(filter, "https://a.b.example.com:8443/x"))
        #expect(try matches(filter, "wss://example.com/socket"))
        #expect(try !matches(filter, "https://notexample.com/"))
        #expect(try !matches(filter, "https://example.com.evil/"))
        #expect(try !matches(filter, "https://evil.com/?u=https://example.com/"))
        #expect(try !matches(filter, "https://evil.com/example.com/"))
    }

    @Test func trailingSeparatorMatchesSeparatorOrEnd() throws {
        let filter = try #require(only("/ads^")).trigger.urlFilter
        #expect(try matches(filter, "https://x.com/ads"))
        #expect(try matches(filter, "https://x.com/ads?x=1"))
        #expect(try matches(filter, "https://x.com/ads/1.png"))
        #expect(try !matches(filter, "https://x.com/adsx"))
        #expect(try !matches(filter, "https://x.com/ads.js"))
    }

    private func anyMatches(_ text: String, _ url: String) throws -> Bool {
        try ABPFilterConverter.convert(text).rules.contains { try matches($0.trigger.urlFilter, url) }
    }

    @Test func domainAnchorMatchesAFullyQualifiedHost() throws {
        #expect(try anyMatches("||example.com^", "https://example.com./x.js"))
        #expect(try anyMatches("||example.com^", "https://sub.example.com.:8443/x.js"))
        #expect(try anyMatches("||example.com^", "https://example.com/x.js"))
        #expect(try !anyMatches("||example.com^", "https://example.com.evil/x.js"))
        #expect(try !anyMatches("||example.com^", "https://example.comx/x.js"))
        #expect(try anyMatches("||example.com^*/track.js", "https://example.com./a/track.js"))
        #expect(try anyMatches("||example.com/ads/", "https://example.com./ads/1.png"))
        let withException = ABPFilterConverter.convertPartitioned("||example.com^\n@@||example.com/ok.js$script").network
        let fqdnRequest = RuleEvaluator.Request(url: "https://example.com./ok.js", resourceType: "script", pageHost: "a.com")
        #expect(try !RuleEvaluator.isBlocked(fqdnRequest, by: withException))
        #expect(try RuleEvaluator.isBlocked(.init(url: "https://example.com./ad.js", resourceType: "script", pageHost: "a.com"),
                                            by: withException))
    }

    @Test func fullyQualifiedTwinsFollowTheirRule() {
        let rules = ABPFilterConverter.convertPartitioned("||example.com^\n||example.com/ads/\n||example.com\n/ads^").network
        #expect(rules == [
            .blockRule(host + #"example\.com[/:]"#), .blockRule(host + #"example\.com\.[/:]"#),
            .blockRule(host + #"example\.com/ads/"#), .blockRule(host + #"example\.com\./ads/"#),
            .blockRule(host + #"example\.com"#),  // already matches `example.com.` as a prefix
            .blockRule("/ads(\(sep).*)?$"),
        ])
    }

    @Test func endAnchor() throws {
        let filter = try #require(only("/banner.gif|")).trigger.urlFilter
        #expect(try matches(filter, "https://x.com/banner.gif"))
        #expect(try !matches(filter, "https://x.com/banner.gif?x"))
        #expect(try !matches(filter, "https://x.com/bannerXgif"))
    }
}
