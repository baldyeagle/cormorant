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

    // MARK: OKLab

    @Test func oklabReferenceValues() {
        // Björn Ottosson's published values for sRGB white, black and primaries.
        let white = RGBColor.white.oklab, black = RGBColor(hex: 0x000000).oklab
        #expect(abs(white.l - 1) < 0.0001 && abs(white.a) < 0.0001 && abs(white.b) < 0.0001)
        #expect(abs(black.l) < 0.0001)
        let red = RGBColor(hex: 0xFF0000).oklab
        #expect(abs(red.l - 0.6279) < 0.001 && abs(red.a - 0.2249) < 0.001 && abs(red.b - 0.1258) < 0.001)
    }

    @Test func oklabRoundTrips() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x1E2327, 0x00EB5B, 0xCC0000, 0x00ADD8, 0x0088CC, 0x7F7F7F] {
            let color = RGBColor(hex: hex)
            #expect(color.oklab.rgb.distance(to: color) < 0.5 / 255, "\(hex)")
        }
    }

    @Test func interpolationRunsThroughOKLab() {
        let red = RGBColor(hex: 0xFF0000), green = RGBColor(hex: 0x00FF00)
        func mix(_ t: Double) -> RGBColor { red.oklab.interpolated(to: green.oklab, fraction: t).rgb }
        #expect(mix(0).distance(to: red) < 0.002)
        #expect(mix(1).distance(to: green) < 0.002)
        // sRGB's midpoint is olive (#808000); OKLab's is a brighter yellow.
        let middle = mix(0.5)
        #expect(middle.relativeLuminance > RGBColor(hex: 0x808000).relativeLuminance + 0.1)
        #expect(abs(middle.oklab.l - (0.6279 + 0.8664) / 2) < 0.002)
    }

    @Test(arguments: [0x00EB5B, 0xCC0000, 0x00ADD8, 0x0088CC, 0xFF00FF] as [UInt32])
    func toningCapsChromaKeepingLightnessAndHue(hex: UInt32) {
        let color = RGBColor(hex: hex)
        let toned = color.toned(maximumChroma: 0.12)
        let (before, after) = (color.oklab, toned.oklab)
        #expect(after.chroma <= 0.12 + 0.003, "\(toned)")
        #expect(abs(after.l - before.l) < 0.01)
        let hue = { (lab: OKLab) in atan2(lab.b, lab.a) }
        #expect(abs(hue(after) - hue(before)) < 0.05)
    }

    @Test func toningLeavesQuietColorsAlone() {
        for hex: UInt32 in [0xFFFFFF, 0x1E2327, 0xEEF1F0, 0x6B7280] {
            #expect(RGBColor(hex: hex).toned(maximumChroma: 0.09).distance(to: RGBColor(hex: hex)) < 0.5 / 255)
        }
    }

    // MARK: Top edge

    private func edge(_ runs: [(UInt32, Int)]) -> TopEdgeSample {
        TopEdgeSample(pixels: runs.flatMap { hex, count in Array(repeating: RGBColor(hex: hex), count: count) })!
    }

    @Test func aSolidEdgeIsDominant() {
        #expect(edge([(0xEEF1F0, 100)]).dominant?.distance(to: RGBColor(hex: 0xEEF1F0)) ?? 1 < 1.5 / 255)
    }

    @Test func textOnABandStillLetsTheBandDominate() {
        // A header with a logo and links: 85% background, the rest ink and accents.
        let sample = edge([(0x070C31, 85), (0xFFFFFF, 10), (0x5865F2, 5)])
        #expect(sample.dominant?.distance(to: RGBColor(hex: 0x070C31)) ?? 1 < 1.5 / 255)
    }

    @Test func nearlyEqualShadesCountAsOne() {
        // A subtle gradient within ΔE 0.04 is still one color.
        let sample = edge([(0x191338, 50), (0x1A143A, 50)])
        #expect(sample.dominant != nil)
    }

    @Test func aMixedEdgeHasNoDominantColor() {
        #expect(edge([(0xFDE68A, 60), (0x00ADD8, 40)]).dominant == nil)
        #expect(edge([(0xFFFFFF, 50), (0x000000, 50)]).dominant == nil)
    }

    @Test func theDominantColorIsAnActualPixel() {
        // White and a near-white within ΔE 0.04: the result is white itself, not their average
        // (which would read as a faint non-default tint).
        let sample = edge([(0xFFFFFF, 60), (0xF4F4F4, 25), (0x000000, 15)])
        #expect(sample.dominant == .white)
        #expect(ChromeTint(themeColor: nil, pageBackground: nil, topEdge: sample, defaultBackground: .white, isDark: false) == nil)
    }

    @Test func aThinBorderAboveAWhiteHeaderIsNotThePagesColor() {
        // Like Stack Overflow: a 3 px orange top border. The row below disagrees, so the edge is mixed.
        let border = Array(repeating: RGBColor(hex: 0xF48225), count: 50)
        let header = Array(repeating: RGBColor.white, count: 50)
        let sample = TopEdgeSample(rows: [border, header])
        #expect(sample?.dominant == nil)
        #expect(TopEdgeSample(rows: [header, header])?.dominant == .white)
        #expect(ChromeTint(themeColor: nil, pageBackground: .white, topEdge: sample, defaultBackground: .white, isDark: false) == nil)
    }

    @Test func aColorSpreadOverSeveralCellsStillDominates() {
        // Shades of one color straddling cell boundaries (ΔE under 0.04 apart), beside three small
        // solid colors that each fill a cell of their own.
        var pixels: [RGBColor] = []
        for i in 0..<81 { pixels.append(RGBColor(red: 0.5 + Double(i % 9) * 0.004, green: 0.3, blue: 0.3)) }
        for hex: UInt32 in [0x0000FF, 0x00FF00, 0xFFFF00] { pixels += Array(repeating: RGBColor(hex: hex), count: 6) }
        #expect(TopEdgeSample(pixels: pixels)?.dominant != nil)
    }

    @Test func dominanceIsLinearInTheRow() {
        // A wide solid row is the worst case for an all-pairs search; this one must stay instant.
        let row = Array(repeating: RGBColor(hex: 0x070C31), count: 20_000)
        let start = ContinuousClock.now
        #expect(TopEdgeSample(pixels: row)?.dominant == RGBColor(hex: 0x070C31))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func emptySampleIsNil() {
        #expect(TopEdgeSample(pixels: []) == nil)
    }

    // MARK: Choosing the strip color

    @Test func theDominantEdgeColorWinsExactly() {
        // GitHub: theme-color #1E2327 above a #EEF1F0 banner.
        let tint = ChromeTint(themeColor: RGBColor(hex: 0x1E2327), pageBackground: .white,
                              topEdge: edge([(0xEEF1F0, 100)]), defaultBackground: .white, isDark: false)
        #expect(tint?.background.distance(to: RGBColor(hex: 0xEEF1F0)) ?? 1 < 1.5 / 255)
        #expect(tint?.matchesPage == true)
        #expect(tint?.foreground == .dark)
    }

    @Test func aDominantEdgeIsNotToned() {
        // Target's red header stays Target red.
        let tint = ChromeTint(themeColor: RGBColor(hex: 0xCC0000), pageBackground: .white,
                              topEdge: edge([(0xCC0000, 90), (0xFFFFFF, 10)]), defaultBackground: .white, isDark: false)
        #expect(tint?.background.distance(to: RGBColor(hex: 0xCC0000)) ?? 1 < 1.5 / 255)
    }

    @Test func aWhiteEdgeIsTheDefaultChromeWhateverTheThemeColor() {
        // Tripadvisor: neon theme-color, white header.
        #expect(ChromeTint(themeColor: RGBColor(hex: 0x00EB5B), pageBackground: .white,
                           topEdge: edge([(0xFFFFFF, 95), (0x000000, 5)]), defaultBackground: .white, isDark: false) == nil)
    }

    @Test func aThemeColorMatchingMuchOfAMixedEdgeIsUsedExactly() {
        // A #CC0000 band over 70% of the edge: no single color dominates, but toning it would put
        // a muted red right above the band.
        let tint = ChromeTint(themeColor: RGBColor(hex: 0xCC0000), pageBackground: .white,
                              topEdge: edge([(0xCC0000, 70), (0xFFFFFF, 30)]), defaultBackground: .white, isDark: false)
        #expect(tint?.background == RGBColor(hex: 0xCC0000))
        #expect(tint?.matchesPage == true)
    }

    @Test func aThemeColorCloseToAMixedEdgeStandsInToned() {
        let theme = RGBColor(hex: 0x00EB5B)
        let tint = ChromeTint(themeColor: theme, pageBackground: .white,
                              topEdge: edge([(0x00EB5B, 20), (0x10D060, 20), (0xFFFFFF, 40), (0x000000, 20)]),
                              defaultBackground: .white, isDark: false)
        #expect(tint?.matchesPage == false)
        #expect((tint?.background.oklab.chroma ?? 1) <= 0.12 + 0.003)
        #expect(abs((tint?.background.oklab.l ?? 0) - theme.oklab.l) < 0.01)
    }

    @Test func darkModeTonesHarder() {
        let theme = RGBColor(hex: 0x00ADD8)
        let tint = ChromeTint(themeColor: theme, pageBackground: nil, topEdge: nil, defaultBackground: .ink, isDark: true)
        #expect((tint?.background.oklab.chroma ?? 1) <= 0.09 + 0.003)
    }

    @Test func aThemeColorFarFromAMixedEdgeGivesWayToThePageBackground() {
        // go.dev: a yellow banner beside a blue hero at the edge, theme-color cyan, page white.
        let tint = ChromeTint(themeColor: RGBColor(hex: 0x00ADD8), pageBackground: RGBColor(hex: 0xF0F0F0),
                              topEdge: edge([(0xFDE68A, 60), (0x007D9C, 40)]), defaultBackground: .white, isDark: false)
        #expect(tint?.background.distance(to: RGBColor(hex: 0xF0F0F0)) ?? 1 < 1.5 / 255)
        #expect(tint?.matchesPage == false)
        #expect(ChromeTint(themeColor: RGBColor(hex: 0x00ADD8), pageBackground: .white,
                           topEdge: edge([(0xFDE68A, 60), (0x007D9C, 40)]), defaultBackground: .white, isDark: false) == nil)
    }

    @Test func unsampledFallsBackToTheThemeColorToned() {
        let tint = ChromeTint(themeColor: RGBColor(hex: 0xCC0000), pageBackground: .white, topEdge: nil,
                              defaultBackground: .white, isDark: false)
        #expect(tint?.matchesPage == false)
        #expect((tint?.background.oklab.chroma ?? 1) <= 0.12 + 0.003)
    }

    @Test func nothingUsableIsTheDefaultChrome() {
        #expect(ChromeTint(themeColor: nil, pageBackground: nil, topEdge: nil, defaultBackground: .white, isDark: false) == nil)
    }

    @Test func colorsMatchingTheDefaultChromeAreNotATint() {
        func tint(_ theme: RGBColor, on defaultBackground: RGBColor) -> ChromeTint? {
            ChromeTint(themeColor: theme, pageBackground: nil, topEdge: nil, defaultBackground: defaultBackground,
                       isDark: defaultBackground == .ink)
        }
        #expect(tint(.white, on: .white) == nil)
        #expect(tint(RGBColor(hex: 0xFEFEFE), on: .white) == nil)
        #expect(tint(.ink, on: .ink) == nil)
        // A white page in dark mode is a tint: the strip should match the page, not the system.
        #expect(tint(.white, on: .ink)?.foreground == .dark)
        #expect(tint(.ink, on: .white)?.foreground == .light)
    }

    @Test func mostlyTransparentThemeColorsAreSkipped() {
        let faint = RGBColor(red: 1, green: 0, blue: 0, alpha: 0.2)
        #expect(ChromeTint(themeColor: faint, pageBackground: nil, topEdge: nil, defaultBackground: .white, isDark: false) == nil)
        let fallback = ChromeTint(themeColor: faint, pageBackground: RGBColor(hex: 0xE5E7EB), topEdge: nil,
                                  defaultBackground: .white, isDark: false)
        #expect(fallback?.background.distance(to: RGBColor(hex: 0xE5E7EB)) ?? 1 < 1.5 / 255)
    }

    @Test func translucentThemeColorsAreDrawnOverTheDefault() {
        // YouTube's light theme-color is rgba(255, 255, 255, 0.98): over white it's the default chrome.
        let youtube = RGBColor(red: 1, green: 1, blue: 1, alpha: 0.98)
        #expect(ChromeTint(themeColor: youtube, pageBackground: nil, topEdge: nil, defaultBackground: .white, isDark: false) == nil)
        let halfBlack = RGBColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        let tint = ChromeTint(themeColor: halfBlack, pageBackground: nil, topEdge: nil, defaultBackground: .white, isDark: false)
        #expect(tint?.background.alpha == 1)
        #expect(abs((tint?.background.red ?? 0) - 0.5) < 0.0001)
    }

    @Test func wideGamutComponentsAreClamped() {
        let p3Red = RGBColor(red: 1.09, green: -0.23, blue: -0.15)
        #expect(p3Red == RGBColor(red: 1, green: 0, blue: 0))
        #expect(RGBColor(red: .nan, green: .infinity, blue: 0.5).red == 0)
    }
}
