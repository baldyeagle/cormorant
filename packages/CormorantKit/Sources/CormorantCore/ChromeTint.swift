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

/// The browser chrome's tint for a page: its background and which foreground stays legible on it.
public struct ChromeTint: Equatable, Hashable, Sendable {
    public enum Foreground: Sendable {
        /// White text and icons, for dark tints.
        case light
        /// Near-black text and icons, for light tints.
        case dark
    }

    /// Where the color came from.
    public enum Source: Sendable {
        /// The page asked for it (`<meta name="theme-color">`).
        case themeColor
        /// The page's own background; the chrome around the page matches it, but controls drawn
        /// over the page shouldn't, or they'd disappear into it.
        case pageBackground
    }

    /// Opaque.
    public let background: RGBColor
    public let foreground: Foreground
    public let source: Source

    /// Colors this transparent say too little about the page to tint with.
    static let minimumAlpha = 0.5
    /// Closer than this to the default chrome, the default chrome is used as is.
    static let defaultTolerance = 2.0 / 255

    public init(background: RGBColor, source: Source = .themeColor) {
        self.source = source
        self.background = RGBColor(red: background.red, green: background.green, blue: background.blue)
        // Whichever foreground contrasts more; ties go to dark, which reads better on mid tones.
        self.foreground = Self.lightForeground.contrastRatio(with: self.background)
            > Self.darkForeground.contrastRatio(with: self.background) ? .light : .dark
    }

    /// The page's tint: its theme color if it has a usable one, otherwise its background.
    /// Nil when neither is usable or the result is the default chrome anyway.
    /// - Parameters:
    ///   - themeColor: `<meta name="theme-color">`, as WebKit resolved it for the current appearance.
    ///   - pageBackground: the color under the page (`underPageBackgroundColor`), or nil to skip it.
    ///   - defaultBackground: the chrome's own background in the current appearance; translucent
    ///     colors are drawn over it.
    public init?(themeColor: RGBColor?, pageBackground: RGBColor?, defaultBackground: RGBColor) {
        let candidates = [(themeColor, Source.themeColor), (pageBackground, .pageBackground)]
        guard let (color, source) = candidates.lazy
            .compactMap({ color, source in color.map { ($0, source) } })
            .first(where: { color, _ in color.alpha >= Self.minimumAlpha }) else { return nil }
        let opaque = color.composited(over: defaultBackground)
        guard opaque.distance(to: defaultBackground) > Self.defaultTolerance else { return nil }
        self.init(background: opaque, source: source)
    }

    static let lightForeground = RGBColor.white
    static let darkForeground = RGBColor.ink
}
