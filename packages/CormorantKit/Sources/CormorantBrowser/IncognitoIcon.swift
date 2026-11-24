import Foundation

/// The sunglasses that stand for Incognito, in the style picked in Settings › Appearance. Drawn by the
/// app (`IncognitoGlyph`) rather than taken from SF Symbols, which has one pair: each style is a few
/// paths on a 32 × 16 grid.
public enum IncognitoIcon: String, CaseIterable, Identifiable, Codable {
    case wayfarer, aviator, round, catEye, shield, browline, classic, glint

    public static let `default` = IncognitoIcon.wayfarer

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .wayfarer: "Wayfarer"
        case .aviator: "Aviator"
        case .round: "Round"
        case .catEye: "Cat-Eye"
        case .shield: "Shield"
        case .browline: "Browline"
        case .classic: "Classic"
        case .glint: "Glint"
        }
    }
}
