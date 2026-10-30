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

    /// This color in OKLab (alpha ignored).
    public var oklab: OKLab { OKLab(self) }

    /// This color with its OKLCH chroma limited to `maximumChroma`, keeping lightness and hue.
    public func toned(maximumChroma: Double) -> RGBColor {
        oklab.withMaximumChroma(maximumChroma).rgb
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// A color in OKLab (Björn Ottosson's perceptual space): `l` lightness 0...1, `a` green–red,
/// `b` blue–yellow. Euclidean distance approximates perceived difference (ΔE).
public struct OKLab: Equatable, Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    public init(_ color: RGBColor) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(color.red), linear(color.green), linear(color.blue))
        let lms = (cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b),
                   cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b),
                   cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b))
        self.l = 0.2104542553 * lms.0 + 0.7936177850 * lms.1 - 0.0040720468 * lms.2
        self.a = 1.9779984951 * lms.0 - 2.4285922050 * lms.1 + 0.4505937099 * lms.2
        self.b = 0.0259040371 * lms.0 + 0.7827717662 * lms.1 - 0.8086757660 * lms.2
    }

    /// In sRGB, clamped to its gamut.
    public var rgb: RGBColor {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (lc, mc, sc) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055 }
        return RGBColor(red: gamma(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
                        green: gamma(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
                        blue: gamma(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc))
    }

    /// OKLCH chroma.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// ΔE: Euclidean distance in OKLab. About 0.02 is a just-noticeable difference.
    public func distance(to other: OKLab) -> Double {
        let (dl, da, db) = (l - other.l, a - other.a, b - other.b)
        return (dl * dl + da * da + db * db).squareRoot()
    }

    public func interpolated(to other: OKLab, fraction t: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    /// Same lightness and hue, chroma at most `maximum`.
    public func withMaximumChroma(_ maximum: Double) -> OKLab {
        let chroma = self.chroma
        guard chroma > maximum, chroma > 0 else { return self }
        let scale = maximum / chroma
        return OKLab(l: l, a: a * scale, b: b * scale)
    }
}

/// Pixels from the top edge of the visible page: what the status-bar strip sits against.
public struct TopEdgeSample: Equatable, Hashable, Sendable {
    /// Opaque, every row.
    public let pixels: [RGBColor]
    /// A color (one of the pixels, exactly) covering at least `dominantShare` of every row within
    /// `matchDistance`; nil when the edge is a mix (a photo, a gradient, a striped header) or the
    /// rows disagree (a thin colored border along the top of a white header).
    public let dominant: RGBColor?

    /// ΔE within which two pixels count as the same color.
    public static let matchDistance = 0.04
    public static let dominantShare = 0.8

    /// One row. Nil when empty.
    public init?(pixels: [RGBColor]) {
        self.init(rows: [pixels])
    }

    /// Rows from the top edge down. Nil when there are no pixels.
    public init?(rows: [[RGBColor]]) {
        let rows = rows.filter { !$0.isEmpty }.map { $0.map { RGBColor(red: $0.red, green: $0.green, blue: $0.blue) } }
        guard !rows.isEmpty else { return nil }
        pixels = rows.flatMap { $0 }
        let colors = rows.map(Self.dominantColor(of:))
        if let edge = colors[0],
           colors.allSatisfy({ $0.map { $0.oklab.distance(to: edge.oklab) <= Self.matchDistance } ?? false }) {
            dominant = edge
        } else {
            dominant = nil
        }
    }

    /// The fraction of the edge within `distance` (ΔE) of `color`.
    public func share(near color: RGBColor, within distance: Double) -> Double {
        let target = color.oklab
        return Double(pixels.count { $0.oklab.distance(to: target) <= distance }) / Double(pixels.count)
    }

    /// Linear in the row: pixels are binned into OKLab cells `matchDistance` wide, and candidates (the
    /// pixel nearest the mean of each of the fullest cells, and of the fullest cell with its neighbors,
    /// for a color whose shades spread over several cells) are each tried against the whole row.
    private static func dominantColor(of row: [RGBColor]) -> RGBColor? {
        let labs = row.map(\.oklab)
        func cell(_ lab: OKLab) -> [Int] {
            [lab.l, lab.a, lab.b].map { Int(($0 / matchDistance).rounded(.down)) }
        }
        let cells = Dictionary(grouping: labs.indices, by: { cell(labs[$0]) })
        // Fullest first; ties in a fixed order, so the choice doesn't vary between launches.
        let ranked = cells.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count
                                                                      : $0.key.lexicographicallyPrecedes($1.key) }
        func nearestToMean(of members: [Int]) -> Int? {
            let n = Double(members.count)
            let mean = OKLab(l: members.reduce(0) { $0 + labs[$1].l } / n,
                             a: members.reduce(0) { $0 + labs[$1].a } / n,
                             b: members.reduce(0) { $0 + labs[$1].b } / n)
            return members.min { labs[$0].distance(to: mean) < labs[$1].distance(to: mean) }
        }
        var groups = ranked.prefix(3).map(\.value)
        if let fullest = ranked.first?.key {
            let neighbors = (-1...1).flatMap { dl in (-1...1).flatMap { da in (-1...1).map { db in
                [fullest[0] + dl, fullest[1] + da, fullest[2] + db]
            } } }
            groups.append(neighbors.flatMap { cells[$0] ?? [] })
        }
        let needed = dominantShare * Double(labs.count)
        for members in groups where !members.isEmpty {
            guard let center = nearestToMean(of: members) else { continue }
            let near = labs.count { $0.distance(to: labs[center]) <= matchDistance }
            if Double(near) >= needed { return row[center] }
        }
        return nil
    }
}

/// The status-bar strip's color for a page, and which status-bar foreground reads on it.
///
/// The strip should continue the page, so the color at the page's top edge wins when one color
/// dominates it, exactly. Otherwise the page's `theme-color` stands in: exactly when it matches much
/// of the edge, toned when it's only close, and not at all when it isn't; then the page's background,
/// toned. A toned stand-in has its chroma limited, to keep a loud color (neon green, pure red) that
/// doesn't match the page from becoming a wall of it.
public struct ChromeTint: Equatable, Hashable, Sendable {
    public enum Foreground: Sendable {
        /// White text and icons, for dark tints.
        case light
        /// Near-black text and icons, for light tints.
        case dark
    }

    /// Opaque.
    public let background: RGBColor
    public let foreground: Foreground
    /// The color is what the page shows at its top edge, not a toned-down stand-in.
    public let matchesPage: Bool

    /// Colors this transparent say too little about the page to tint with.
    static let minimumAlpha = 0.5
    /// Closer than this (per channel) to the default chrome, the default chrome is used as is.
    static let defaultTolerance = 2.0 / 255
    /// A `theme-color` matching this much of a mixed edge (within `TopEdgeSample.matchDistance`) is
    /// used exactly.
    static let exactShare = 0.5
    /// A `theme-color` stands in, toned, for a mixed edge when this much of it is within `closeDistance`.
    static let closeShare = 0.3
    static let closeDistance = 0.1
    /// OKLCH chroma limits for a stand-in color, lower in dark mode where color glows more.
    static let lightMaximumChroma = 0.12
    static let darkMaximumChroma = 0.09

    public init(background: RGBColor, matchesPage: Bool = true) {
        self.background = RGBColor(red: background.red, green: background.green, blue: background.blue)
        self.matchesPage = matchesPage
        // Whichever foreground contrasts more; ties go to dark, which reads better on mid tones.
        self.foreground = Self.lightForeground.contrastRatio(with: self.background)
            > Self.darkForeground.contrastRatio(with: self.background) ? .light : .dark
    }

    /// Nil when nothing is usable or the result is the default chrome anyway.
    /// - Parameters:
    ///   - themeColor: `<meta name="theme-color">`, as WebKit resolved it for the current appearance.
    ///   - pageBackground: the color under the page (`underPageBackgroundColor`), or nil to skip it.
    ///   - topEdge: what the page shows along its top edge, or nil if it couldn't be sampled.
    ///   - defaultBackground: the chrome's own background in the current appearance; translucent
    ///     colors are drawn over it.
    ///   - isDark: dark appearance, for the stand-in chroma limit.
    public init?(themeColor: RGBColor?, pageBackground: RGBColor?, topEdge: TopEdgeSample?,
                 defaultBackground: RGBColor, isDark: Bool) {
        func opaque(_ color: RGBColor?) -> RGBColor? {
            guard let color, color.alpha >= Self.minimumAlpha else { return nil }
            return color.composited(over: defaultBackground)
        }
        let color: RGBColor
        let matchesPage: Bool
        if let dominant = topEdge?.dominant {
            (color, matchesPage) = (dominant, true)
        } else if let theme = opaque(themeColor), let topEdge,
                  topEdge.share(near: theme, within: TopEdgeSample.matchDistance) >= Self.exactShare {
            (color, matchesPage) = (theme, true)
        } else if let theme = opaque(themeColor),
                  topEdge.map({ $0.share(near: theme, within: Self.closeDistance) >= Self.closeShare }) ?? true {
            (color, matchesPage) = (theme, false)
        } else if let background = opaque(pageBackground) {
            (color, matchesPage) = (background, false)
        } else {
            return nil
        }
        guard color.distance(to: defaultBackground) > Self.defaultTolerance else { return nil }
        let maximumChroma = isDark ? Self.darkMaximumChroma : Self.lightMaximumChroma
        self.init(background: matchesPage ? color : color.toned(maximumChroma: maximumChroma),
                  matchesPage: matchesPage)
    }

    static let lightForeground = RGBColor.white
    static let darkForeground = RGBColor.ink
}
