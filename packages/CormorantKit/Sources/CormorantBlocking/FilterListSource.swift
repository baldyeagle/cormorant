import Foundation

/// Upstream filter lists that feed the content blocker.
public enum FilterListSource: String, CaseIterable, Hashable, Sendable {
    case easyList
    case easyPrivacy

    public static let easyListURL = URL(string: "https://easylist.to/easylist/easylist.txt")!
    public static let easyPrivacyURL = URL(string: "https://easylist.to/easylist/easyprivacy.txt")!

    public var url: URL {
        switch self {
        case .easyList: Self.easyListURL
        case .easyPrivacy: Self.easyPrivacyURL
        }
    }
}
