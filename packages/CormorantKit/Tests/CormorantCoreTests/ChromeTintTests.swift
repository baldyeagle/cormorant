import Foundation
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
        (0xFF0000, .dark),    // pure red: 5.0 against ink vs 4.0 against white
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

    @Test func thePageBackgroundIsTheTint() {
        let tint = ChromeTint(pageBackground: RGBColor(hex: 0xB91C1C), defaultBackground: .white)
        #expect(tint?.background == RGBColor(hex: 0xB91C1C))
        #expect(tint?.foreground == .light)
    }

    @Test func noPageIsTheDefaultChrome() {
        #expect(ChromeTint(pageBackground: nil, defaultBackground: .white) == nil)
    }

    @Test func colorsMatchingTheDefaultChromeAreNotATint() {
        #expect(ChromeTint(pageBackground: .white, defaultBackground: .white) == nil)
        #expect(ChromeTint(pageBackground: RGBColor(hex: 0xFEFEFE), defaultBackground: .white) == nil)
        #expect(ChromeTint(pageBackground: .ink, defaultBackground: .ink) == nil)
        // A white page in dark mode is a tint: the status bar should read on the page, not the system.
        #expect(ChromeTint(pageBackground: .white, defaultBackground: .ink)?.foreground == .dark)
        #expect(ChromeTint(pageBackground: .ink, defaultBackground: .white)?.foreground == .light)
    }

    @Test func mostlyTransparentColorsAreSkipped() {
        let faint = RGBColor(red: 1, green: 0, blue: 0, alpha: 0.2)
        #expect(ChromeTint(pageBackground: faint, defaultBackground: .white) == nil)
    }

    @Test func translucentColorsAreDrawnOverTheDefault() {
        let nearlyWhite = RGBColor(red: 1, green: 1, blue: 1, alpha: 0.98)
        #expect(ChromeTint(pageBackground: nearlyWhite, defaultBackground: .white) == nil)
        let halfBlack = RGBColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        let tint = ChromeTint(pageBackground: halfBlack, defaultBackground: .white)
        #expect(tint?.background.alpha == 1)
        #expect(abs((tint?.background.red ?? 0) - 0.5) < 0.0001)
    }

    @Test func wideGamutComponentsAreClamped() {
        let p3Red = RGBColor(red: 1.09, green: -0.23, blue: -0.15)
        #expect(p3Red == RGBColor(red: 1, green: 0, blue: 0))
        #expect(RGBColor(red: .nan, green: .infinity, blue: 0.5).red == 0)
    }
}
