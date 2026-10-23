import Foundation

/// Upstream filter lists that feed the content blocker.
public enum FilterListSource: String, CaseIterable, Hashable, Sendable, Codable {
    case easyList
    case easyPrivacy
    /// EasyList Cookie List: hides and blocks consent banners.
    case easyListCookie

    public var url: URL {
        switch self {
        case .easyList: URL(string: "https://easylist.to/easylist/easylist.txt")!
        case .easyPrivacy: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
        case .easyListCookie: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!
        }
    }

    public var displayName: String {
        switch self {
        case .easyList: "EasyList (ads)"
        case .easyPrivacy: "EasyPrivacy (trackers)"
        case .easyListCookie: "EasyList Cookie (consent banners)"
        }
    }

    public static let defaultSet: Set<FilterListSource> = [.easyList, .easyPrivacy, .easyListCookie]
}
