import Foundation

/// A color in sRGB, components 0...1 (out-of-range values from wide-gamut colors are clamped).
public struct RGBColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    /// Vialumi's near-black (#030712), the dark chrome background and the dark foreground.
    public static let ink = RGBColor(hex: 0x030712)

    /// WCAG 2 relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1...21.
    public func contrastRatio(with other: RGBColor) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color drawn over an opaque `background`.
    public func composited(over background: RGBColor) -> RGBColor {
        RGBColor(red: red * alpha + background.red * (1 - alpha),
                 green: green * alpha + background.green * (1 - alpha),
                 blue: blue * alpha + background.blue * (1 - alpha))
    }

    /// Largest per-channel difference, alpha ignored.
    public func distance(to other: RGBColor) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// The page's own color behind the status bar, and the status-bar style that reads on it.
///
/// The page runs up under the status bar, so what's behind the clock is the page: above its top, the
/// color WebKit paints under it (its background). That one color, per page, sets the status bar's
/// style, and fills the iPhone Duo's status-bar column beside the page.
public struct ChromeTint: Equatable, Hashable, Sendable {
    public enum Foreground: Sendable {
        /// White text and icons, for dark backgrounds.
        case light
        /// Near-black text and icons, for light backgrounds.
        case dark
    }

    /// Opaque.
    public let background: RGBColor
    public let foreground: Foreground

    /// Colors this transparent say too little about the page to go by.
    static let minimumAlpha = 0.5
    /// Closer than this (per channel) to the default chrome, the default chrome is used as is.
    static let defaultTolerance = 2.0 / 255

    public init(background: RGBColor) {
        self.background = RGBColor(red: background.red, green: background.green, blue: background.blue)
        // Whichever foreground contrasts more; ties go to dark, which reads better on mid tones.
        self.foreground = Self.lightForeground.contrastRatio(with: self.background)
            > Self.darkForeground.contrastRatio(with: self.background) ? .light : .dark
    }

    /// Nil when there's no usable color or it's the default chrome anyway.
    /// - Parameters:
    ///   - pageBackground: the color under the page (`underPageBackgroundColor`), or nil before a page.
    ///   - defaultBackground: the chrome's own background in the current appearance; a translucent
    ///     page color is drawn over it.
    public init?(pageBackground: RGBColor?, defaultBackground: RGBColor) {
        guard let pageBackground, pageBackground.alpha >= Self.minimumAlpha else { return nil }
        let color = pageBackground.composited(over: defaultBackground)
        guard color.distance(to: defaultBackground) > Self.defaultTolerance else { return nil }
        self.init(background: color)
    }

    static let lightForeground = RGBColor.white
    static let darkForeground = RGBColor.ink
}
