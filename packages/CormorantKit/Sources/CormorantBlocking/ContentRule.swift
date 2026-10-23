import Foundation

/// One rule in WebKit's content-blocker JSON format.
/// See https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
public struct ContentRule: Codable, Sendable, Equatable {
    public struct Trigger: Codable, Sendable, Equatable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var loadContext: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case loadContext = "load-context"
        }

        public init(urlFilter: String, urlFilterIsCaseSensitive: Bool? = nil, resourceType: [String]? = nil,
                    loadType: [String]? = nil, ifDomain: [String]? = nil, unlessDomain: [String]? = nil,
                    loadContext: [String]? = nil) {
            self.urlFilter = urlFilter
            self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
            self.resourceType = resourceType
            self.loadType = loadType
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.loadContext = loadContext
        }
    }

    public struct Action: Codable, Sendable, Equatable {
        public var type: String  // "block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"
        public var selector: String?

        public init(type: String, selector: String? = nil) {
            self.type = type
            self.selector = selector
        }

        public static let block = Action(type: "block")
        public static let ignorePrevious = Action(type: "ignore-previous-rules")
        public static func hide(_ selector: String) -> Action { Action(type: "css-display-none", selector: selector) }
    }

    public var trigger: Trigger
    public var action: Action

    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }
}

/// Result of converting one filter list.
public struct ConversionResult: Sendable, Equatable {
    public var rules: [ContentRule]
    public var skippedLines: Int
    public init(rules: [ContentRule], skippedLines: Int) {
        self.rules = rules
        self.skippedLines = skippedLines
    }
}

extension ContentRule {
    /// Serializes rules into the JSON array WebKit's `WKContentRuleListStore` expects.
    /// Hand-written (rather than `JSONEncoder`) because lists have 100k+ rules and this runs on every
    /// refresh; output is equivalent to `JSONEncoder` with nil keys omitted.
    public static func encodedRuleList(_ rules: [ContentRule]) -> String {
        var out = ""
        out.reserveCapacity(rules.count * 96)
        out.append("[")
        for (index, rule) in rules.enumerated() {
            if index > 0 { out.append(",") }
            out.append("{\"trigger\":{\"url-filter\":")
            appendJSONString(rule.trigger.urlFilter, to: &out)
            if let caseSensitive = rule.trigger.urlFilterIsCaseSensitive {
                out.append(",\"url-filter-is-case-sensitive\":")
                out.append(caseSensitive ? "true" : "false")
            }
            appendArray("resource-type", rule.trigger.resourceType, to: &out)
            appendArray("load-type", rule.trigger.loadType, to: &out)
            appendArray("if-domain", rule.trigger.ifDomain, to: &out)
            appendArray("unless-domain", rule.trigger.unlessDomain, to: &out)
            appendArray("load-context", rule.trigger.loadContext, to: &out)
            out.append("},\"action\":{\"type\":")
            appendJSONString(rule.action.type, to: &out)
            if let selector = rule.action.selector {
                out.append(",\"selector\":")
                appendJSONString(selector, to: &out)
            }
            out.append("}}")
        }
        out.append("]")
        return out
    }

    private static func appendArray(_ key: String, _ values: [String]?, to out: inout String) {
        guard let values else { return }
        out.append(",\"")
        out.append(key)
        out.append("\":[")
        for (index, value) in values.enumerated() {
            if index > 0 { out.append(",") }
            appendJSONString(value, to: &out)
        }
        out.append("]")
    }

    private static func appendJSONString(_ value: String, to out: inout String) {
        out.append("\"")
        var needsEscaping = false
        for byte in value.utf8 where byte < 0x20 || byte == 0x22 || byte == 0x5C {
            needsEscaping = true
            break
        }
        if !needsEscaping {
            out.append(value)
        } else {
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out.append("\\\"")
                case "\\": out.append("\\\\")
                case "\n": out.append("\\n")
                case "\r": out.append("\\r")
                case "\t": out.append("\\t")
                default:
                    if scalar.value < 0x20 {
                        let hex = String(scalar.value, radix: 16)
                        out.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
        }
        out.append("\"")
    }
}
