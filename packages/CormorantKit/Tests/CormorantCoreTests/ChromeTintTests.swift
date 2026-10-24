import Testing
@testable import CormorantCore

@Suite struct ChromeTintTests {
    @Test func luminanceEndpoints() {
        #expect(RGBColor.white.relativeLuminance == 1)
        #expect(RGBColor(hex: 0x000000).relativeLuminance == 0)
        #expect(abs(RGBColor.white.contrastRatio(with: RGBColor(hex: 0x000000)) - 21) < 0.0001)
    }

    @Test func contrastIsSymmetric() {
        let a = RGBColor(hex: 0x1E2327), b = RGBColor(hex: 0xFDE047)
        #expect(a.contrastRatio(with: b) == b.contrastRatio(with: a))
    }

    @Test(arguments: [
        // Near-white and near-black, which read as "no color" but still need the right foreground.
        (0xFFFFFF, ChromeTint.Foreground.dark),
        (0xF6F8FA, .dark),
        (0xFEFEFE, .dark),
        (0x000000, .light),
        (0x0F0F0F, .light),
        (0x030712, .light),
        // Brand-ish colors.
        (0x1E2327, .light),   // GitHub
        (0xB91C1C, .light),   // deep red
        (0xFF0000, .dark),    // pure red: 5.25 against ink vs 4.0 against white
        (0xFDE047, .dark),    // yellow
        (0x2563EB, .light),   // blue
        (0x22C55E, .dark),    // green
        (0xFF6600, .dark),    // Hacker News orange
        (0x808080, .dark),
    ])
    func foreground(hex: Int, expected: ChromeTint.Foreground) {
        #expect(ChromeTint(background: RGBColor(hex: UInt32(hex))).foreground == expected)
    }

    @Test func chosenForegroundAlwaysContrastsAtLeastAsMuch() {
        // Every 8-bit grey and a sweep of hues: the choice is never the worse of the two.
        var samples = (0...255).map { RGBColor(red: Double($0) / 255, green: Double($0) / 255, blue: Double($0) / 255) }
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 51) {
                    samples.append(RGBColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
                }
            }
        }
        for color in samples {
            let tint = ChromeTint(background: color)
            let light = RGBColor.white.contrastRatio(with: color)
            let dark = RGBColor.ink.contrastRatio(with: color)
            let chosen = tint.foreground == .light ? light : dark
            #expect(chosen >= max(light, dark) - 0.0001, "\(color)")
            // With two foregrounds this far apart, the better one always clears 4.5:1.
            #expect(chosen >= 4.4, "\(color)")
        }
    }

    @Test func themeColorWinsOverPageBackground() {
        let tint = ChromeTint(themeColor: RGBColor(hex: 0x1E2327), pageBackground: RGBColor(hex: 0xFDE047),
                              defaultBackground: .white)
        #expect(tint?.background == RGBColor(hex: 0x1E2327))
        #expect(tint?.foreground == .light)
        #expect(tint?.source == .themeColor)
    }

    @Test func pageBackgroundIsTheFallback() {
        let tint = ChromeTint(themeColor: nil, pageBackground: RGBColor(hex: 0xFDE047), defaultBackground: .white)
        #expect(tint?.background == RGBColor(hex: 0xFDE047))
        #expect(tint?.source == .pageBackground)
    }

    @Test func nothingUsableIsTheDefaultChrome() {
        #expect(ChromeTint(themeColor: nil, pageBackground: nil, defaultBackground: .white) == nil)
    }

    @Test func colorsMatchingTheDefaultChromeAreNotATint() {
        #expect(ChromeTint(themeColor: .white, pageBackground: nil, defaultBackground: .white) == nil)
        #expect(ChromeTint(themeColor: RGBColor(hex: 0xFEFEFE), pageBackground: nil, defaultBackground: .white) == nil)
        #expect(ChromeTint(themeColor: .ink, pageBackground: nil, defaultBackground: .ink) == nil)
        // A white page in dark mode is a tint: the chrome should match the page, not the system.
        #expect(ChromeTint(themeColor: .white, pageBackground: nil, defaultBackground: .ink)?.foreground == .dark)
        #expect(ChromeTint(themeColor: .ink, pageBackground: nil, defaultBackground: .white)?.foreground == .light)
    }

    @Test func mostlyTransparentColorsAreSkipped() {
        let clear = RGBColor(red: 1, green: 0, blue: 0, alpha: 0)
        let faint = RGBColor(red: 1, green: 0, blue: 0, alpha: 0.2)
        #expect(ChromeTint(themeColor: clear, pageBackground: nil, defaultBackground: .white) == nil)
        let fallback = ChromeTint(themeColor: faint, pageBackground: RGBColor(hex: 0x2563EB), defaultBackground: .white)
        #expect(fallback?.background == RGBColor(hex: 0x2563EB))
        #expect(fallback?.source == .pageBackground)
    }

    @Test func translucentColorsAreDrawnOverTheDefault() {
        // YouTube's light theme-color is rgba(255, 255, 255, 0.98): over white it's the default chrome.
        let youtube = RGBColor(red: 1, green: 1, blue: 1, alpha: 0.98)
        #expect(ChromeTint(themeColor: youtube, pageBackground: nil, defaultBackground: .white) == nil)
        let halfBlack = RGBColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        let tint = ChromeTint(themeColor: halfBlack, pageBackground: nil, defaultBackground: .white)
        #expect(tint?.background.alpha == 1)
        #expect(abs((tint?.background.red ?? 0) - 0.5) < 0.0001)
    }

    @Test func wideGamutComponentsAreClamped() {
        let p3Red = RGBColor(red: 1.09, green: -0.23, blue: -0.15)
        #expect(p3Red == RGBColor(red: 1, green: 0, blue: 0))
        #expect(RGBColor(red: .nan, green: .infinity, blue: 0.5).red == 0)
    }
}
