import Foundation

/// Converts Adblock Plus filter syntax (EasyList family) into WebKit content rules.
///
/// What is converted:
/// - Network rules: `||host^` domain anchors (each with a twin rule for the fully qualified host
///   `host.`, so `https://example.com./ad.js` is blocked too), `|` start/end anchors, `*` wildcards, `^` separators,
///   `$third-party` / `$~third-party`, `$domain=`, resource types (including `~type` negations),
///   `$match-case`, `$popup`, `$document`, `$important` (treated as a normal block), `$all`
///   (a block with no resource-type restriction).
/// - `@@` exceptions become the same trigger with `ignore-previous-rules`. Page-level exceptions
///   (`$document`, `$generichide`, `$elemhide` on a plain `||host^` pattern) become `.*` triggers
///   restricted to that host and are ordered so they only cancel what ABP says they cancel.
/// - Element hiding `##selector` (generic and domain-specific) becomes `css-display-none` with url-filter `.*`.
/// - `#@#` element-hiding exceptions are applied at conversion time: a generic hiding rule gets the
///   exception's domains as `unless-domain`, a domain-specific one has those domains removed.
///
/// What is skipped (and counted, see `Statistics`): regex filters `/.../`, extended CSS (`#?#`,
/// `:-abp-*`, `:contains(`, `:xpath(`, `:has-text(`, `:upward(` ...), native `:has(` unless
/// `Options.allowsNativeHas`, scriptlets/snippets (`#$#`, `#%#`, `##+js(`), HTML filters (`##^`, `$$`),
/// options WebKit cannot express (`$csp`, `$redirect`, `$removeparam`, `$rewrite`, `$replace`, `$header`,
/// `$cookie`, `$badfilter`, `$denyallow`, `$inline-script`, `$empty`, `$mp4`, `$method`, ...),
/// non-ASCII URL patterns, rules whose only domains are unrepresentable (`example.*` entity
/// wildcards, IDN), and patterns that would match every URL without a domain restriction.
///
/// Mixed `$domain=a.com|~sub.a.com` on a block rule: WebKit cannot combine `if-domain` and
/// `unless-domain`, so we emit the block with `if-domain: [*a.com]` immediately followed by an
/// `ignore-previous-rules` carve-out with the same trigger and `if-domain: [*sub.a.com]` (only for
/// excluded domains that are subdomains of an included one; other excludes are irrelevant). These
/// pairs are emitted before every other block, so a carve-out can only cancel earlier carve-out
/// blocks, never an unrelated generic rule such as `||ads.com^$script`. For exceptions and element
/// hiding, the excluded domains are dropped (the exception/hide applies slightly more broadly).
///
/// `#@#` exceptions for a subdomain of a domain-specific hide (`sub.a.com#@#.x` against `a.com##.x`)
/// cannot be expressed either and are counted as skipped (`cosmeticException`), not applied.
public enum ABPFilterConverter {
    /// Bump whenever conversion output can change for the same input text. Compiled-list identifiers
    /// and cached metadata include it, so cached WebKit lists from an older converter are rebuilt.
    public static let converterVersion = 2

    public struct Options: Sendable, Equatable {
        /// WebKit supports native `:has()`, but it is expensive for style invalidation when used in a
        /// large always-on stylesheet, so `##` rules using it are skipped unless this is set.
        public var allowsNativeHas: Bool

        public init(allowsNativeHas: Bool = false) {
            self.allowsNativeHas = allowsNativeHas
        }

        public static let `default` = Options()
    }

    /// Why a filter line produced no rule.
    public enum SkipReason: String, Sendable, CaseIterable, Codable, Error {
        case regexFilter
        case unsupportedOption
        case conflictingOptions
        case unsupportedDomain
        case nonASCIIPattern
        case tooBroad
        case extendedCSS
        case invalidSelector
        /// `selector { style }` rules: style injection, not hiding.
        case cssInjection
        case scriptlet
        case htmlFilter
        case cosmeticException
        case unsupportedException
        case malformed
    }

    public struct Statistics: Sendable, Equatable {
        /// Every line in the input.
        public var lines = 0
        /// Blank lines, `!` comments and `[Adblock Plus 2.0]`-style headers. Not counted as skipped.
        public var ignoredLines = 0
        /// Filter lines that were processed (converted or skipped).
        public var filterLines = 0
        public var skipped: [SkipReason: Int] = [:]
        /// For `.unsupportedOption`, which option caused the skip.
        public var unsupportedOptions: [String: Int] = [:]

        public init() {}

        public var skippedTotal: Int { skipped.values.reduce(0, +) }
        public var convertedLines: Int { filterLines - skippedTotal }

        mutating func skip(_ reason: SkipReason, option: String? = nil) {
            skipped[reason, default: 0] += 1
            if let option { unsupportedOptions[option, default: 0] += 1 }
        }

        /// One-line human-readable summary, e.g. for logs.
        public var summary: String {
            let reasons = skipped.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }
            return "lines=\(lines) ignored=\(ignoredLines) filters=\(filterLines) converted=\(convertedLines) "
                + "skipped=\(skippedTotal) [\(reasons.joined(separator: ", "))]"
        }
    }

    /// Conversion output split by how WebKit should compile it.
    ///
    /// `ignore-previous-rules` cancels *every* earlier rule in the same compiled list that matches,
    /// so network exceptions and element-hiding rules should live in different lists: a network
    /// exception matching a page's own URL would otherwise cancel that page's hiding rules.
    public struct Conversion: Sendable, Equatable {
        /// Ordered: blocks, network exceptions, `$document` exceptions.
        public var network: [ContentRule]
        /// Ordered: generic hides, `$generichide` exceptions, domain hides, `$elemhide` exceptions,
        /// `$document` exceptions.
        public var cosmetic: [ContentRule]
        public var statistics: Statistics

        /// Everything in one list, ordered so page-level exceptions still only cancel what they should.
        public var combined: [ContentRule] { cosmetic + network }
    }

    /// Converts a whole filter list into rules for a single WebKit list.
    public static func convert(_ filterListText: String) -> ConversionResult {
        let conversion = convertPartitioned(filterListText)
        return ConversionResult(rules: conversion.combined, skippedLines: conversion.statistics.skippedTotal)
    }

    /// Converts a whole filter list, keeping network and cosmetic rules apart (see `Conversion`).
    public static func convertPartitioned(_ filterListText: String, options: Options = .default) -> Conversion {
        var builder = Builder(options: options)
        var text = filterListText
        text.withUTF8 { buffer in
            var lineStart = 0
            let count = buffer.count
            while lineStart <= count {
                var lineEnd = lineStart
                while lineEnd < count && buffer[lineEnd] != 0x0A { lineEnd += 1 }
                if lineStart < count || lineEnd > lineStart {
                    builder.process(line: UnsafeBufferPointer(rebasing: buffer[lineStart..<lineEnd]))
                }
                lineStart = lineEnd + 1
            }
        }
        return builder.finish()
    }

    /// Splits rules into lists of at most `maxPerList` rules (WebKit's limit is 150,000).
    ///
    /// `ignore-previous-rules` only affects earlier rules in the same compiled list, so exceptions are
    /// duplicated into every chunk that contains a rule they follow, keeping their position relative
    /// to that chunk's rules. With converter output (exceptions after the rules they except) this means
    /// every chunk ends with the full set of exceptions. Exceptions that follow no rule at all are
    /// no-ops and are dropped, so a list of only exceptions yields no chunks. If the exceptions alone
    /// would not fit in a chunk, the input is split in plain order instead (exceptions then only
    /// apply within their own chunk).
    public static func chunk(_ rules: [ContentRule], maxPerList: Int = 150_000) -> [[ContentRule]] {
        precondition(maxPerList > 0, "maxPerList must be positive")
        var primaries: [ContentRule] = []
        // `position` = number of primary rules before the exception.
        var exceptions: [(position: Int, rule: ContentRule)] = []
        primaries.reserveCapacity(rules.count)
        for rule in rules {
            if rule.action.type == ContentRule.Action.ignorePrevious.type {
                if !primaries.isEmpty { exceptions.append((primaries.count, rule)) }
            } else {
                primaries.append(rule)
            }
        }
        guard !primaries.isEmpty else { return [] }

        var chunks: [[ContentRule]] = []
        var start = 0
        var firstRelevant = 0
        while start < primaries.count {
            while firstRelevant < exceptions.count && exceptions[firstRelevant].position <= start {
                firstRelevant += 1
            }
            let relevant = exceptions.count - firstRelevant
            let capacity = maxPerList - relevant
            if capacity < 1 {
                return stride(from: 0, to: rules.count, by: maxPerList).map {
                    Array(rules[$0..<min($0 + maxPerList, rules.count)])
                }
            }
            let end = min(primaries.count, start + capacity)
            var chunk: [ContentRule] = []
            chunk.reserveCapacity(end - start + relevant)
            var next = firstRelevant
            for index in start..<end {
                while next < exceptions.count && exceptions[next].position <= index {
                    chunk.append(exceptions[next].rule)
                    next += 1
                }
                chunk.append(primaries[index])
            }
            while next < exceptions.count {
                chunk.append(exceptions[next].rule)
                next += 1
            }
            chunks.append(chunk)
            start = end
        }
        return chunks
    }
}

// MARK: - Builder

extension ABPFilterConverter {
    private struct HideRule {
        var selector: String
        var ifDomain: [String]?
        var unlessDomain: [String]?
    }

    private enum HideException {
        case everywhere
        case domains([String])
    }

    private struct Domains {
        var includes: [String] = []
        var excludes: [String] = []
        var droppedIncludes = 0
        var droppedExcludes = 0
    }

    private struct ParsedOptions {
        var thirdParty: Bool?
        var includeTypes: Set<String> = []
        var excludeTypes: Set<String> = []
        var domains: String?
        var matchCase = false
        var all = false
        var document = false
        var genericHide = false
        var elemHide = false
    }

    /// ABP types that apply when a rule names no types (ABP excludes `document` and `popup`).
    private static let defaultTypes: Set<String> = [
        "script", "image", "stylesheet", "object", "xmlhttprequest", "subdocument", "font", "media",
        "websocket", "ping", "other",
    ]

    private static let typeAliases: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "stylesheet", "css": "stylesheet",
        "object": "object", "object-subrequest": "object", "xmlhttprequest": "xmlhttprequest",
        "xhr": "xmlhttprequest", "subdocument": "subdocument", "frame": "subdocument", "font": "font",
        "media": "media", "websocket": "websocket", "ping": "ping", "beacon": "ping", "other": "other",
        "popup": "popup", "document": "document", "doc": "document",
    ]

    /// ABP type → WebKit `resource-type`.
    private static let webKitType: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "object": "other",
        "xmlhttprequest": "fetch", "subdocument": "document", "font": "font", "media": "media",
        "websocket": "websocket", "ping": "ping", "other": "other", "popup": "popup", "document": "document",
    ]

    private static let webKitTypeOrder = [
        "document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup",
        "ping", "fetch", "websocket", "other",
    ]

    /// Options that change nothing for WebKit and are safe to ignore.
    private static let ignorableOptions: Set<String> = ["important", "collapse", "~collapse", "_", "~match-case"]

    private struct Builder {
        let options: ABPFilterConverter.Options
        var stats = Statistics()
        var blocks: [ContentRule] = []
        /// Domain-restricted blocks each followed by their subdomain carve-out exception.
        var carveOutBlocks: [ContentRule] = []
        var networkExceptions: [ContentRule] = []
        var documentExceptions: [ContentRule] = []
        var genericHides: [HideRule] = []
        var genericHideExceptions: [ContentRule] = []
        var specificHides: [HideRule] = []
        var elemHideExceptions: [ContentRule] = []
        /// selector → (exception line id, exception)
        var hideExceptions: [String: [(id: Int, exception: HideException)]] = [:]
        var hideExceptionCount = 0

        init(options: ABPFilterConverter.Options) {
            self.options = options
        }

        mutating func process(line raw: UnsafeBufferPointer<UInt8>) {
            stats.lines += 1
            var start = 0
            var end = raw.count
            while start < end && isSpace(raw[start]) { start += 1 }
            while end > start && isSpace(raw[end - 1]) { end -= 1 }
            if start == end { stats.ignoredLines += 1; return }
            let line = UnsafeBufferPointer(rebasing: raw[start..<end])
            let first = line[0]
            if first == ascii("!") { stats.ignoredLines += 1; return }
            if first == ascii("[") && line[line.count - 1] == ascii("]") { stats.ignoredLines += 1; return }
            if first == ascii("#") && (line.count == 1 || line[1] == ascii(" ") || line[1] == ascii("!")) {
                stats.ignoredLines += 1
                return
            }
            stats.filterLines += 1
            if processCosmetic(line) { return }
            processNetwork(line)
        }

        // MARK: Cosmetic

        /// Returns false if the line is not a cosmetic filter.
        private mutating func processCosmetic(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
            let count = line.count
            var hash = -1
            for index in 0..<count {
                let byte = line[index]
                if byte == ascii("#") { hash = index; break }
                if isCosmeticPrefixBreaker(byte) {
                    // AdGuard HTML filtering `example.com$$script[...]`.
                    if byte == ascii("$"), index + 1 < count, line[index + 1] == ascii("$") || line[index + 1] == ascii("@") {
                        stats.skip(.htmlFilter)
                        return true
                    }
                    return false
                }
            }
            guard hash >= 0, hash + 1 < count else { return false }
            func at(_ offset: Int) -> UInt8 { hash + offset < count ? line[hash + offset] : 0 }

            let selectorStart: Int
            let isException: Bool
            switch at(1) {
            case ascii("#"):
                selectorStart = hash + 2
                isException = false
            case ascii("@"):
                if at(2) == ascii("#") {
                    selectorStart = hash + 3
                    isException = true
                } else if (at(2) == ascii("?") || at(2) == ascii("$") || at(2) == ascii("%")) && (at(3) == ascii("#") || at(4) == ascii("#")) {
                    stats.skip(.cosmeticException)
                    return true
                } else {
                    return false
                }
            case ascii("?"):
                guard at(2) == ascii("#") else { return false }
                stats.skip(.extendedCSS)
                return true
            case ascii("$"), ascii("%"):
                guard at(2) == ascii("#") || (at(2) == ascii("?") && at(3) == ascii("#")) else { return false }
                stats.skip(.scriptlet)
                return true
            default:
                return false
            }

            let selector = trimmedString(line, from: selectorStart, to: count)
            guard !selector.isEmpty else { stats.skip(.malformed); return true }
            if selector.hasPrefix("+js(") { stats.skip(.scriptlet); return true }
            if selector.hasPrefix("^") { stats.skip(.htmlFilter); return true }

            let domains = parseDomains(UnsafeBufferPointer(rebasing: line[0..<hash]), separator: ascii(","))

            if isException {
                if !domains.excludes.isEmpty || domains.droppedExcludes > 0 || domains.droppedIncludes > 0 && domains.includes.isEmpty {
                    stats.skip(.cosmeticException)
                    return true
                }
                let exception: HideException = domains.includes.isEmpty ? .everywhere : .domains(domains.includes)
                hideExceptions[selector, default: []].append((hideExceptionCount, exception))
                hideExceptionCount += 1
                return true
            }

            if selector.hasSuffix("}") && selector.contains("{") { stats.skip(.cssInjection); return true }
            switch validateSelector(selector, allowsHas: options.allowsNativeHas) {
            case .valid: break
            case .extended: stats.skip(.extendedCSS); return true
            case .invalid: stats.skip(.invalidSelector); return true
            }

            if !domains.includes.isEmpty {
                specificHides.append(HideRule(selector: selector, ifDomain: domains.includes.map { "*" + $0 }))
            } else if domains.droppedIncludes > 0 || domains.droppedExcludes > 0 {
                stats.skip(.unsupportedDomain)
            } else if !domains.excludes.isEmpty {
                genericHides.append(HideRule(selector: selector, unlessDomain: domains.excludes.map { "*" + $0 }))
            } else {
                genericHides.append(HideRule(selector: selector))
            }
            return true
        }

        // MARK: Network

        private mutating func processNetwork(_ line: UnsafeBufferPointer<UInt8>) {
            var start = 0
            let isException = line.count >= 2 && line[0] == ascii("@") && line[1] == ascii("@")
            if isException { start = 2 }

            // Options follow the last `$` when it is followed by something shaped like an option name.
            var patternEnd = line.count
            var optionsText: String?
            var dollar = line.count - 1
            while dollar >= start && line[dollar] != ascii("$") { dollar -= 1 }
            if dollar >= start, dollar + 1 < line.count {
                let next = line[dollar + 1]
                if isLowerAlpha(next) || next == ascii("~") || next == ascii("_") || isUpperAlpha(next) || isDigit(next) {
                    patternEnd = dollar
                    optionsText = String(decoding: UnsafeBufferPointer(rebasing: line[(dollar + 1)..<line.count]), as: UTF8.self)
                }
            }

            let patternBytes = UnsafeBufferPointer(rebasing: line[start..<patternEnd])
            var regexFilter: String?
            if patternBytes.count > 2 && patternBytes[0] == ascii("/") && patternBytes[patternBytes.count - 1] == ascii("/") {
                // `/.../` is a regex. Keep the ones WebKit's regex subset can express.
                guard let converted = ABPFilterConverter.webKitRegex(
                    fromABPRegex: UnsafeBufferPointer(rebasing: patternBytes[1..<(patternBytes.count - 1)])) else {
                    stats.skip(.regexFilter)
                    return
                }
                regexFilter = converted
            }

            var parsed = ParsedOptions()
            if let optionsText {
                for rawOption in optionsText.split(separator: ",", omittingEmptySubsequences: true) {
                    if let unsupported = apply(option: rawOption, to: &parsed) {
                        stats.skip(.unsupportedOption, option: unsupported)
                        return
                    }
                }
            }

            var pattern = Array(patternBytes)
            if !parsed.matchCase {
                for index in pattern.indices where isUpperAlpha(pattern[index]) { pattern[index] += 32 }
            }

            var domains = Domains()
            if let domainText = parsed.domains {
                let bytes = Array(domainText.utf8)
                domains = bytes.withUnsafeBufferPointer { parseDomains($0, separator: ascii("|")) }
                if domains.includes.isEmpty && (domains.droppedIncludes > 0 || domains.droppedExcludes > 0) {
                    stats.skip(.unsupportedDomain)
                    return
                }
            }

            // Page-level exceptions.
            if isException && (parsed.document || parsed.genericHide || parsed.elemHide) {
                let hosts: [String]?
                if let host = ABPFilterConverter.pureHost(pattern) {
                    hosts = [host]
                } else if ABPFilterConverter.matchesEverything(pattern), !domains.includes.isEmpty {
                    hosts = domains.includes
                } else {
                    hosts = nil
                }
                if let hosts {
                    let trigger = ContentRule.Trigger(urlFilter: ".*", ifDomain: hosts.map { "*" + $0 })
                    let rule = ContentRule(trigger: trigger, action: .ignorePrevious)
                    if parsed.document {
                        documentExceptions.append(rule)
                    } else {
                        if parsed.genericHide { genericHideExceptions.append(rule) }
                        if parsed.elemHide { elemHideExceptions.append(rule) }
                    }
                    return
                }
                if !parsed.document {
                    stats.skip(.unsupportedException)
                    return
                }
                // `$document` on a non-host pattern: fall through to a plain exception for document loads.
            } else if parsed.genericHide || parsed.elemHide {
                stats.skip(.malformed)
                return
            }

            var resourceTypes: [String]?
            if parsed.all {
                resourceTypes = nil
            } else if !parsed.includeTypes.isEmpty {
                resourceTypes = ABPFilterConverter.webKitTypes(parsed.includeTypes)
            } else if !parsed.excludeTypes.isEmpty {
                resourceTypes = ABPFilterConverter.webKitTypes(ABPFilterConverter.defaultTypes.subtracting(parsed.excludeTypes))
                if resourceTypes?.isEmpty == true {
                    stats.skip(.conflictingOptions)
                    return
                }
            } else if parsed.document {
                resourceTypes = ["document"]
            }
            if parsed.document, var types = resourceTypes, !types.contains("document") {
                types.append("document")
                resourceTypes = ABPFilterConverter.webKitTypeOrder.filter(types.contains)
            }

            let urlFilter: String
            var fullyQualifiedFilter: String?
            if let regexFilter {
                urlFilter = regexFilter
            } else {
                switch ABPFilterConverter.regex(for: pattern) {
                case .failure(let reason):
                    stats.skip(reason)
                    return
                case .success(let converted):
                    // A match-everything pattern needs a domain, or a type that never breaks pages
                    // (EasyPrivacy's `*$ping,third-party`).
                    let harmlessTypes = resourceTypes.map { !$0.isEmpty && $0.allSatisfy { $0 == "ping" } } ?? false
                    if converted.matchesEverything && domains.includes.isEmpty && domains.excludes.isEmpty && !harmlessTypes {
                        stats.skip(.tooBroad)
                        return
                    }
                    urlFilter = converted.filter
                    fullyQualifiedFilter = converted.fullyQualifiedFilter
                }
            }

            let loadType: [String]? = parsed.thirdParty.map { $0 ? ["third-party"] : ["first-party"] }
            var trigger = ContentRule.Trigger(
                urlFilter: urlFilter,
                urlFilterIsCaseSensitive: parsed.matchCase ? true : nil,
                resourceType: resourceTypes,
                loadType: loadType
            )

            if !domains.includes.isEmpty {
                trigger.ifDomain = domains.includes.map { "*" + $0 }
            } else if !domains.excludes.isEmpty {
                trigger.unlessDomain = domains.excludes.map { "*" + $0 }
            }

            /// The rule, then its fully qualified host twin (`example.com.`) if there is one.
            func withTwin(_ rule: ContentRule) -> [ContentRule] {
                guard let fullyQualifiedFilter else { return [rule] }
                var twin = rule
                twin.trigger.urlFilter = fullyQualifiedFilter
                return [rule, twin]
            }

            if isException {
                networkExceptions.append(contentsOf: withTwin(ContentRule(trigger: trigger, action: .ignorePrevious)))
                return
            }

            if !domains.includes.isEmpty && !domains.excludes.isEmpty {
                let carveOuts = domains.excludes.filter { exclude in
                    domains.includes.contains { exclude == $0 || exclude.hasSuffix("." + $0) }
                }
                if !carveOuts.isEmpty {
                    var exceptionTrigger = trigger
                    exceptionTrigger.ifDomain = carveOuts.map { "*" + $0 }
                    carveOutBlocks.append(contentsOf: withTwin(ContentRule(trigger: trigger, action: .block)))
                    carveOutBlocks.append(contentsOf: withTwin(ContentRule(trigger: exceptionTrigger, action: .ignorePrevious)))
                    return
                }
            }
            blocks.append(contentsOf: withTwin(ContentRule(trigger: trigger, action: .block)))
        }

        /// Applies one option; returns the option name if it is unsupported.
        private func apply(option rawOption: Substring, to parsed: inout ParsedOptions) -> String? {
            let option = rawOption.trimmingCharacters(in: .whitespaces)
            var name = option
            var value: String?
            if let equals = option.firstIndex(of: "=") {
                name = String(option[..<equals])
                value = String(option[option.index(after: equals)...])
            }
            name = name.lowercased()
            if ABPFilterConverter.ignorableOptions.contains(name) { return nil }
            let negated = name.hasPrefix("~")
            let bare = negated ? String(name.dropFirst()) : name

            switch bare {
            case "third-party", "3p":
                parsed.thirdParty = !negated
            case "first-party", "1p":
                parsed.thirdParty = negated
            case "match-case":
                parsed.matchCase = !negated
            case "domain", "from":
                guard !negated, let value, !value.isEmpty else { return name }
                parsed.domains = parsed.domains.map { $0 + "|" + value } ?? value
            case "all":
                guard !negated else { return name }
                parsed.all = true
            case "generichide", "ghide":
                guard !negated else { return name }
                parsed.genericHide = true
            case "elemhide", "ehide":
                guard !negated else { return name }
                parsed.elemHide = true
            default:
                guard value == nil, let type = ABPFilterConverter.typeAliases[bare] else { return name }
                if type == "document" && !negated {
                    parsed.document = true
                    parsed.includeTypes.insert(type)
                } else if negated {
                    parsed.excludeTypes.insert(type)
                } else {
                    parsed.includeTypes.insert(type)
                }
            }
            if let value, bare != "domain", bare != "from", !value.isEmpty { return name }
            return nil
        }

        // MARK: Finish

        mutating func finish() -> Conversion {
            var appliedExceptions = Set<Int>()
            /// Exceptions that hit a rule they could not be expressed against (a subdomain of an
            /// `if-domain` entry). Counted as skipped even if they applied to some other rule.
            var unrepresentableExceptions = Set<Int>()

            func applyExceptions(to rule: HideRule) -> HideRule? {
                guard let exceptions = hideExceptions[rule.selector] else { return rule }
                var rule = rule
                for (id, exception) in exceptions {
                    switch exception {
                    case .everywhere:
                        appliedExceptions.insert(id)
                        return nil
                    case .domains(let excepted):
                        if let ifDomain = rule.ifDomain {
                            func bare(_ entry: String) -> String { entry.hasPrefix("*") ? String(entry.dropFirst()) : entry }
                            let remaining = ifDomain.filter { entry in
                                let domain = bare(entry)
                                return !excepted.contains { domain == $0 || domain.hasSuffix("." + $0) }
                            }
                            if remaining.count < ifDomain.count { appliedExceptions.insert(id) }
                            // `sub.a.com#@#` against `a.com##`: would need if-domain plus unless-domain.
                            let inexpressible = excepted.contains { exceptedDomain in
                                remaining.contains { exceptedDomain.hasSuffix("." + bare($0)) }
                            }
                            if inexpressible { unrepresentableExceptions.insert(id) }
                            if remaining.isEmpty { return nil }
                            rule.ifDomain = remaining
                        } else {
                            appliedExceptions.insert(id)
                            var unless = rule.unlessDomain ?? []
                            for domain in excepted where !unless.contains("*" + domain) { unless.append("*" + domain) }
                            rule.unlessDomain = unless
                        }
                    }
                }
                return rule
            }

            func hideRule(_ rule: HideRule) -> ContentRule {
                ContentRule(
                    trigger: ContentRule.Trigger(urlFilter: ".*", ifDomain: rule.ifDomain, unlessDomain: rule.unlessDomain),
                    action: .hide(rule.selector)
                )
            }

            var cosmetic: [ContentRule] = []
            cosmetic.reserveCapacity(genericHides.count + specificHides.count + genericHideExceptions.count
                + elemHideExceptions.count + documentExceptions.count)
            for rule in genericHides { if let rule = applyExceptions(to: rule) { cosmetic.append(hideRule(rule)) } }
            cosmetic.append(contentsOf: genericHideExceptions)
            for rule in specificHides { if let rule = applyExceptions(to: rule) { cosmetic.append(hideRule(rule)) } }
            cosmetic.append(contentsOf: elemHideExceptions)
            cosmetic.append(contentsOf: documentExceptions)

            let unmatched = hideExceptionCount - appliedExceptions.count
            let partial = unrepresentableExceptions.intersection(appliedExceptions).count
            if unmatched + partial > 0 { stats.skipped[.cosmeticException, default: 0] += unmatched + partial }

            // Only document exceptions and no hides means the cosmetic list would do nothing.
            if cosmetic.count == documentExceptions.count { cosmetic = [] }
            // Carve-out pairs first: their exceptions must not cancel the generic blocks that follow.
            var network = carveOutBlocks
            network.append(contentsOf: blocks)
            network.append(contentsOf: networkExceptions)
            network.append(contentsOf: documentExceptions)
            if blocks.isEmpty && carveOutBlocks.isEmpty { network = [] }

            return Conversion(network: network, cosmetic: cosmetic, statistics: stats)
        }

        // MARK: Domains

        private func parseDomains(_ bytes: UnsafeBufferPointer<UInt8>, separator: UInt8) -> Domains {
            var result = Domains()
            var index = 0
            let count = bytes.count
            while index <= count {
                var end = index
                while end < count && bytes[end] != separator { end += 1 }
                var entryStart = index
                var entryEnd = end
                while entryStart < entryEnd && isSpace(bytes[entryStart]) { entryStart += 1 }
                while entryEnd > entryStart && isSpace(bytes[entryEnd - 1]) { entryEnd -= 1 }
                if entryStart < entryEnd {
                    var negated = false
                    if bytes[entryStart] == ascii("~") { negated = true; entryStart += 1 }
                    // IPv6 literals (`[::1]`) never match WebKit's domain conditions; ignore them.
                    if entryStart < entryEnd && bytes[entryStart] == ascii("[") {
                        index = end + 1
                        continue
                    }
                    // Entity wildcard `example.*`: expand to common public suffixes.
                    var entity = false
                    if entryEnd - entryStart > 2 && bytes[entryEnd - 1] == ascii("*") && bytes[entryEnd - 2] == ascii(".") {
                        entity = true
                        entryEnd -= 2
                    }
                    var domain: [UInt8] = []
                    domain.reserveCapacity(entryEnd - entryStart)
                    var representable = entryStart < entryEnd
                    for position in entryStart..<entryEnd {
                        var byte = bytes[position]
                        if isUpperAlpha(byte) { byte += 32 }
                        if isLowerAlpha(byte) || isDigit(byte) || byte == ascii(".") || byte == ascii("-") || byte == ascii("_") {
                            domain.append(byte)
                        } else {
                            representable = false
                            break
                        }
                    }
                    if representable, domain.first == ascii(".") { domain.removeFirst() }
                    if representable && !domain.isEmpty {
                        let string = String(decoding: domain, as: UTF8.self)
                        let expanded = entity ? ABPFilterConverter.entitySuffixes.map { string + $0 } : [string]
                        if negated { result.excludes.append(contentsOf: expanded) } else { result.includes.append(contentsOf: expanded) }
                    } else if negated {
                        result.droppedExcludes += 1
                    } else {
                        result.droppedIncludes += 1
                    }
                }
                index = end + 1
            }
            return result
        }
    }
}

// MARK: - Patterns

extension ABPFilterConverter {
    struct ConvertedPattern: Equatable {
        var filter: String
        var matchesEverything: Bool
        /// For `||host^...` patterns, the same filter matching the fully qualified form of the host
        /// (`example.com./x.js`). Emitted as a twin rule: an optional `\.?` inside the filter is
        /// equivalent but makes WebKit's compile about 6x slower on EasyList-sized lists.
        var fullyQualifiedFilter: String? = nil
    }

    /// Public suffixes used to expand entity domains like `example.*` (WebKit has no TLD wildcard).
    /// Same idea as AdGuard's Safari converter; covers the sites lists target in practice.
    static let entitySuffixes = [
        "com", "net", "org", "info", "biz", "io", "co", "me", "tv", "cc", "eu", "xyz", "online", "site", "to",
        "de", "fr", "it", "es", "nl", "be", "ch", "at", "pl", "pt", "se", "no", "dk", "fi", "cz", "sk", "hu",
        "ro", "bg", "gr", "hr", "si", "rs", "lt", "lv", "ee", "ie", "uk", "co.uk", "ru", "ua", "by", "kz",
        "tr", "com.tr", "il", "co.il", "ae", "sa", "eg", "ma", "za", "co.za", "ng", "ke", "in", "co.in", "pk",
        "jp", "co.jp", "kr", "co.kr", "cn", "com.cn", "tw", "com.tw", "hk", "com.hk", "sg", "com.sg", "id",
        "co.id", "my", "com.my", "ph", "com.ph", "th", "co.th", "vn", "com.vn", "au", "com.au", "nz", "co.nz",
        "ca", "us", "mx", "com.mx", "br", "com.br", "ar", "com.ar", "cl", "pe", "com.pe", "com.co", "ve", "uy",
    ].map { "." + $0 }

    /// Converts the body of an ABP `/regex/` filter when it only uses what WebKit supports: no
    /// alternation, no counted repetition, no lookaround/backreferences, `^` only first, `$` only last,
    /// balanced `()` and `[]`, and no quantifier at the start, after another quantifier (so no lazy
    /// `*?` or possessive `++`), or right after `(`. `\d` and `\w` are rewritten as classes. The result
    /// must also be accepted by `NSRegularExpression`. Returns nil otherwise, so one bad regex cannot
    /// make WebKit reject a whole compiled list.
    static func webKitRegex(fromABPRegex body: UnsafeBufferPointer<UInt8>) -> String? {
        enum Previous { case start, quantifier, groupOpen, atom }
        var output = ""
        var index = 0
        let count = body.count
        var inClass = false
        var groupDepth = 0
        var previous = Previous.start
        while index < count {
            let byte = body[index]
            guard byte >= 0x20 && byte < 0x7F else { return nil }
            if inClass {
                if byte == ascii("\\") {
                    guard index + 1 < count else { return nil }
                    let next = body[index + 1]
                    // `\d`/`\w` inside a class and other letter escapes are not supported.
                    if isLowerAlpha(next) || isUpperAlpha(next) || isDigit(next) { return nil }
                    if next != ascii("/") { output.append("\\") }
                    output.unicodeScalars.append(Unicode.Scalar(next))
                    index += 2
                    continue
                }
                if byte == ascii("]") {
                    inClass = false
                    previous = .atom
                }
                output.unicodeScalars.append(Unicode.Scalar(byte))
                index += 1
                continue
            }
            switch byte {
            case ascii("|"), ascii("{"), ascii("}"):
                return nil
            case ascii("\\"):
                guard index + 1 < count else { return nil }
                let next = body[index + 1]
                previous = .atom
                if next == ascii("d") {
                    output += "[0-9]"
                } else if next == ascii("w") {
                    output += "[a-zA-Z0-9_]"
                } else if next == ascii("/") {
                    output += "/"
                } else if isLowerAlpha(next) || isUpperAlpha(next) || isDigit(next) || next >= 0x7F || next < 0x20 {
                    return nil  // \s \b \D \1 ... not supported
                } else {
                    output.append("\\")
                    output.unicodeScalars.append(Unicode.Scalar(next))
                }
                index += 2
                continue
            case ascii("("):
                if index + 1 < count && body[index + 1] == ascii("?") { return nil }
                groupDepth += 1
                previous = .groupOpen
            case ascii(")"):
                groupDepth -= 1
                if groupDepth < 0 || previous == .groupOpen { return nil }
                previous = .atom
            case ascii("["):
                inClass = true
            case ascii("]"):
                return nil  // `]` without a matching `[`
            case ascii("*"), ascii("+"), ascii("?"):
                if previous != .atom { return nil }
                previous = .quantifier
            case ascii("^"):
                if index != 0 { return nil }
            case ascii("$"):
                if index != count - 1 { return nil }
                previous = .atom
            default:
                previous = .atom
            }
            output.unicodeScalars.append(Unicode.Scalar(byte))
            index += 1
        }
        guard !inClass, groupDepth == 0, !output.isEmpty else { return nil }
        guard (try? NSRegularExpression(pattern: output)) != nil else { return nil }
        return output
    }

    private static let separatorClass = "[^a-zA-Z0-9_.%-]"
    static let hostAnchorPrefix = "^[^:]+:(//)?([^/]+\\.)?"

    /// Converts an ABP URL pattern (no options) into a WebKit `url-filter` regex.
    static func regex(for pattern: [UInt8]) -> Result<ConvertedPattern, SkipReason> {
        var body = pattern[...]
        var output = ""
        var hostAnchored = false
        var startAnchored = false
        if body.count >= 2 && body[body.startIndex] == ascii("|") && body[body.startIndex + 1] == ascii("|") {
            hostAnchored = true
            body = body.dropFirst(2)
        } else if body.first == ascii("|") {
            startAnchored = true
            body = body.dropFirst()
        }
        var endAnchored = false
        if body.last == ascii("|") {
            endAnchored = true
            body = body.dropLast()
        }
        if !hostAnchored && !startAnchored {
            while body.first == ascii("*") { body = body.dropFirst() }
        }
        if !endAnchored {
            while body.last == ascii("*") { body = body.dropLast() }
        }

        if body.isEmpty {
            if hostAnchored { return .failure(.malformed) }
            return .success(ConvertedPattern(filter: ".*", matchesEverything: true))
        }

        if hostAnchored { output = hostAnchorPrefix } else if startAnchored { output = "^" }
        var inHost = hostAnchored
        /// Where the host part ends in `output`, for the fully qualified twin.
        var hostEnd: String.Index?
        var previousWasWildcard = false
        let last = body.endIndex - 1
        for index in body.indices {
            let byte = body[index]
            if byte >= 0x80 { return .failure(.nonASCIIPattern) }
            if byte < 0x20 || byte == 0x7F { return .failure(.malformed) }
            switch byte {
            case ascii("*"):
                if !previousWasWildcard { output += ".*" }
                previousWasWildcard = true
                inHost = false
                continue
            case ascii("^"):
                if inHost && index != body.startIndex {
                    hostEnd = output.endIndex
                    output += "[/:]"
                } else if index == last {
                    output += endAnchored ? separatorClass + "?" : "(" + separatorClass + ".*)?$"
                } else {
                    output += separatorClass
                }
                inHost = false
            case ascii("."), ascii("?"), ascii("+"), ascii("("), ascii(")"), ascii("["), ascii("]"),
                 ascii("{"), ascii("}"), ascii("\\"), ascii("$"), ascii("|"):
                output.append("\\")
                output.unicodeScalars.append(Unicode.Scalar(byte))
                if byte != ascii(".") { inHost = false }
            default:
                if inHost && index != body.startIndex && (byte == ascii("/") || byte == ascii(":")) {
                    hostEnd = output.endIndex
                }
                output.unicodeScalars.append(Unicode.Scalar(byte))
                if !(isLowerAlpha(byte) || isUpperAlpha(byte) || isDigit(byte) || byte == ascii("-") || byte == ascii("_")) {
                    inHost = false
                }
            }
            previousWasWildcard = false
        }
        if endAnchored { output += "$" }
        var fullyQualified: String?
        if let hostEnd {
            fullyQualified = output
            fullyQualified?.insert(contentsOf: "\\.", at: hostEnd)
        }
        return .success(ConvertedPattern(filter: output, matchesEverything: false, fullyQualifiedFilter: fullyQualified))
    }

    /// `||example.com^`, `||example.com`, `||example.com/`, `||example.com^|` → `example.com`.
    static func pureHost(_ pattern: [UInt8]) -> String? {
        guard pattern.count > 2, pattern[0] == ascii("|"), pattern[1] == ascii("|") else { return nil }
        var end = pattern.count
        if end > 2 && pattern[end - 1] == ascii("|") { end -= 1 }
        if end > 2 && (pattern[end - 1] == ascii("^") || pattern[end - 1] == ascii("/")) { end -= 1 }
        guard end > 2 else { return nil }
        var host: [UInt8] = []
        for index in 2..<end {
            var byte = pattern[index]
            if isUpperAlpha(byte) { byte += 32 }
            guard isLowerAlpha(byte) || isDigit(byte) || byte == ascii(".") || byte == ascii("-") || byte == ascii("_") else {
                return nil
            }
            host.append(byte)
        }
        guard host.last != ascii("."), host.first != ascii(".") else { return nil }
        return String(decoding: host, as: UTF8.self)
    }

    static func matchesEverything(_ pattern: [UInt8]) -> Bool {
        pattern.allSatisfy { $0 == ascii("*") || $0 == ascii("|") } && !(pattern.count >= 2 && pattern[0] == ascii("|") && pattern[1] == ascii("|"))
    }

    private static func webKitTypes(_ abpTypes: Set<String>) -> [String] {
        let mapped = Set(abpTypes.compactMap { webKitType[$0] })
        return webKitTypeOrder.filter(mapped.contains)
    }
}

// MARK: - Selectors

extension ABPFilterConverter {
    enum SelectorVerdict: Equatable {
        case valid
        case extended
        case invalid
    }

    /// Pseudo-classes WebKit's selector parser accepts (verified by `pseudoClassWhitelistCompiles`).
    static let supportedPseudoClasses: Set<String> = [
        "not", "is", "where", "matches", "-webkit-any", "nth-child", "nth-last-child", "nth-of-type",
        "nth-last-of-type", "first-child", "last-child", "only-child", "first-of-type", "last-of-type",
        "only-of-type", "empty", "root", "scope", "hover", "active", "focus", "focus-within", "focus-visible",
        "visited", "link", "any-link", "target", "checked", "indeterminate", "enabled", "disabled", "read-only",
        "read-write", "placeholder-shown", "required", "optional", "in-range", "out-of-range", "valid",
        "invalid", "default", "lang", "dir", "defined", "host", "state", "modal", "fullscreen", "autofill",
        "-webkit-autofill", "before", "after", "first-line", "first-letter", "playing", "paused",
    ]

    /// Pseudo-elements WebKit accepts after `::`.
    static let supportedPseudoElements: Set<String> = [
        "before", "after", "first-line", "first-letter", "selection", "placeholder", "marker", "backdrop",
        "-webkit-scrollbar", "-webkit-scrollbar-thumb", "-webkit-scrollbar-track", "-webkit-input-placeholder",
        "file-selector-button", "cue", "part", "slotted",
    ]

    /// Procedural / extended CSS from ABP, uBlock Origin and AdGuard.
    static let extendedPseudoClasses: Set<String> = [
        "-abp-has", "-abp-contains", "-abp-properties", "contains", "has-text", "matches-css",
        "matches-css-before", "matches-css-after", "upward", "remove", "xpath", "style", "matches-path",
        "min-text-length", "watch-attr", "watch-attrs", "others", "if", "if-not", "matches-attr", "matches-prop",
        "matches-media", "nth-ancestor", "shadow", "remove-attr", "remove-class", "properties", "has",
    ]

    static func validateSelector(_ selector: String, allowsHas: Bool) -> SelectorVerdict {
        let bytes = Array(selector.utf8)
        let count = bytes.count
        var index = 0
        var inBrackets = false
        var parenDepth = 0
        var quote: UInt8 = 0
        while index < count {
            let byte = bytes[index]
            if byte < 0x20 || byte == 0x7F { return .invalid }
            if byte == ascii("\\") {
                if index + 1 >= count { return .invalid }
                index += 2
                continue
            }
            if quote != 0 {
                if byte == quote { quote = 0 }
                index += 1
                continue
            }
            switch byte {
            case ascii("\""), ascii("'"):
                quote = byte
            case ascii("["):
                if inBrackets { return .invalid }
                inBrackets = true
            case ascii("]"):
                if !inBrackets { return .invalid }
                inBrackets = false
            case _ where inBrackets:
                break
            case ascii("("):
                parenDepth += 1
            case ascii(")"):
                parenDepth -= 1
                if parenDepth < 0 { return .invalid }
            case ascii("{"), ascii("}"), ascii(";"):
                return .invalid
            case ascii(":"):
                var cursor = index + 1
                var isElement = false
                if cursor < count && bytes[cursor] == ascii(":") { isElement = true; cursor += 1 }
                let nameStart = cursor
                while cursor < count {
                    let c = bytes[cursor]
                    guard isLowerAlpha(c) || isUpperAlpha(c) || isDigit(c) || c == ascii("-") || c == ascii("_") else { break }
                    cursor += 1
                }
                if cursor == nameStart { return .invalid }
                let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
                if isElement {
                    if !supportedPseudoElements.contains(name) { return .invalid }
                } else if name == "has" {
                    if !allowsHas { return .extended }
                } else if extendedPseudoClasses.contains(name) || name.hasPrefix("-abp-") || name.hasPrefix("-ext-") {
                    return .extended
                } else if !supportedPseudoClasses.contains(name) {
                    return .invalid
                }
                index = cursor
                continue
            default:
                break
            }
            index += 1
        }
        return quote == 0 && !inBrackets && parenDepth == 0 ? .valid : .invalid
    }
}

// MARK: - Byte helpers

@inline(__always) private func ascii(_ character: Unicode.Scalar) -> UInt8 { UInt8(character.value) }
@inline(__always) private func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D }
@inline(__always) private func isLowerAlpha(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }
@inline(__always) private func isUpperAlpha(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
@inline(__always) private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

/// Characters that cannot appear in the domain part of a cosmetic filter.
@inline(__always) private func isCosmeticPrefixBreaker(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x2F, 0x7C, 0x40, 0x22, 0x21, 0x5E, 0x24, 0x3D, 0x3F, 0x26: true  // / | @ " ! ^ $ = ? &
    default: false
    }
}

private func trimmedString(_ line: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String {
    var start = start
    var end = end
    while start < end && isSpace(line[start]) { start += 1 }
    while end > start && isSpace(line[end - 1]) { end -= 1 }
    return String(decoding: UnsafeBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
}
