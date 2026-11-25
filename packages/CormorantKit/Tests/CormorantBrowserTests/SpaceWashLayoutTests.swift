import CoreGraphics
import Foundation
import Testing
@testable import CormorantBrowser

/// The wash lays itself out from the view's shape: the design's numbers on the iPhone it was drawn
/// for, all five ribbons in every other shape, and a layout that scales with the view, which the
/// launch images rely on.
@Suite("Space wash layout")
struct SpaceWashLayoutTests {
    typealias Layout = SpaceWashPainter.Layout

    /// Phones both ways, iPads, a third of an iPad, a Mac window's page, an ultrawide one, a sliver.
    static let shapes: [CGSize] = [
        CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 393, height: 852),
        CGSize(width: 834, height: 1210), CGSize(width: 1210, height: 834), CGSize(width: 320, height: 834),
        CGSize(width: 1192, height: 884), CGSize(width: 3200, height: 1000), CGSize(width: 120, height: 900),
    ]

    @Test func anIPhoneInPortraitGetsTheNumbersItWasDesignedWith() {
        let layout = Layout(size: SpaceWashPainter.referenceSize)
        let diagonal = hypot(402.0, 874.0)
        #expect(layout.reach.isClose(to: diagonal))
        #expect(layout.amplitude.isClose(to: 402 * 0.065))
        #expect(layout.blur.isClose(to: 39))
        #expect(layout.fade.isClose(to: diagonal * 0.45))
        #expect(layout.tint.lowerBound.isClose(to: -diagonal / 2) && layout.tint.upperBound.isClose(to: diagonal / 2))
        for band in 0..<5 {
            #expect(layout.offsets[band].isClose(to: diagonal * (-0.42 + Double(band) * 0.17)))
            #expect(layout.wavelengths[band].isClose(to: diagonal * (1.2 + Double(band) * 0.12)))
        }
    }

    /// Each ribbon sits the same share of the way across every shape, so all five show, at the same
    /// spacing, waviness and softness as on the phone.
    @Test(arguments: shapes)
    func everyShapeShowsAllFiveRibbonsInProportion(size: CGSize) {
        let reference = Layout(size: SpaceWashPainter.referenceSize)
        let referenceAcross = Layout.across(SpaceWashPainter.referenceSize)
        let layout = Layout(size: size)
        let across = Layout.across(size)
        for band in 0..<5 {
            // An edge rolls by the beat's amplitude plus a quarter of it more from its ripple.
            #expect(abs(layout.offsets[band]) + layout.amplitude * 1.25 < across / 2, "ribbon \(band) is off the view")
            #expect((layout.offsets[band] / across).isClose(to: reference.offsets[band] / referenceAcross))
        }
        #expect((layout.amplitude / across).isClose(to: reference.amplitude / referenceAcross))
        #expect((layout.blur / across).isClose(to: reference.blur / referenceAcross))
        // Every path runs past the view's corners.
        #expect(layout.reach >= hypot(size.width, size.height) / 2)
    }

    /// A launch image aspect-fills the screen it's shown on: a screen of the same shape at another size
    /// must get the same picture, scaled.
    @Test(arguments: shapes)
    func theLayoutScalesWithTheView(size: CGSize) {
        let layout = Layout(size: size)
        let doubled = Layout(size: CGSize(width: size.width * 2, height: size.height * 2))
        #expect(doubled.reach.isClose(to: layout.reach * 2))
        #expect(doubled.amplitude.isClose(to: layout.amplitude * 2))
        #expect(doubled.blur.isClose(to: layout.blur * 2))
        #expect(doubled.fade.isClose(to: layout.fade * 2))
        for band in 0..<5 {
            #expect(doubled.offsets[band].isClose(to: layout.offsets[band] * 2))
            #expect(doubled.wavelengths[band].isClose(to: layout.wavelengths[band] * 2))
        }
    }
}

private extension Double {
    func isClose(to other: Double) -> Bool {
        abs(self - other) <= 1e-9 * Swift.max(1, abs(self), abs(other))
    }
}
