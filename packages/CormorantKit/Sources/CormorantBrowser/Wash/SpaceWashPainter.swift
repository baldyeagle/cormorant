import SwiftUI

/// The Space's color washed across a view: five broad diagonal ribbons, lower left to upper right,
/// blended into a tint of the whole view. They roll to a wingbeat's rhythm, a quicker push and then a
/// long, slow recovery, each ribbon a little behind the one before; nothing in it is drawn as a bird.
/// `SpaceWash` draws it live.
///
/// Laid out from the view's own shape (`Layout`), so a phone in either orientation, an iPad and a Mac
/// window each show all five ribbons at the same proportions; an iPhone in portrait
/// (`referenceSize`) gets the numbers it was designed at. The launch screen is this drawing at time
/// zero in `launchColor` (`assets/brand/make-launch-wash.swift` renders it for each shape the launch
/// screen comes in), so the app's first frame is the same picture. Portable (SwiftUI only, no UIKit or
/// AppKit, nothing else from the package) so that script can build it on its own.
public nonisolated enum SpaceWashPainter {
    /// An sRGB color, from a Space's `Swatch` or one of the fixed ones here.
    public struct RGB: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `self` moved `fraction` of the way to `other`.
        public func mixed(with other: RGB, by fraction: Double) -> RGB {
            RGB(red: red + (other.red - red) * fraction,
                green: green + (other.green - green) * fraction,
                blue: blue + (other.blue - blue) * fraction)
        }

        public func color(opacity: Double = 1) -> Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
        }

        public static let white = RGB(red: 1, green: 1, blue: 1)
        public static let black = RGB(red: 0, green: 0, blue: 0)
    }

    /// The shape the wash was designed on (an iPhone 17 Pro's screen in portrait, in points): there,
    /// `Layout` gives exactly the numbers it was designed with.
    public static let referenceSize = CGSize(width: 402, height: 874)
    /// One beat, in seconds.
    public static let period = 5.5
    /// The share of a beat its push takes; the recovery takes the rest.
    private static let push = 0.35
    /// The ribbons' slant: about 30° up from horizontal.
    private static let angle = 0.5
    /// How many ribbons there are.
    private static let ribbons = 5

    /// The launch screen's color: the launch screen can't know the Space, so it has the brand's cyan,
    /// and the app moves it to the Space's once it runs. `BrandCyan` is Display P3, past what sRGB holds;
    /// this is the nearest sRGB color to it. At the few percent the wash uses it, the difference is slight.
    public static func launchColor(dark: Bool) -> RGB {
        dark ? RGB(red: 0, green: 0.872, blue: 0.878) : RGB(red: 0, green: 0.572, blue: 0.59)
    }

    /// What it's drawn on: Vialumi's white, or #030712 (`LaunchBackground`).
    public static func background(dark: Bool) -> RGB {
        dark ? RGB(red: 3 / 255, green: 7 / 255, blue: 18 / 255) : .white
    }

    /// Where everything goes in a view of a given size. Measured from the view's center, in a frame
    /// turned to the ribbons' slant: along them, and across them (downward, toward the lower right).
    ///
    /// Everything across the ribbons (where each sits, how far its edge rolls, how far it fades, the
    /// blur) scales with how far the view reaches across them, so all five fit in any shape; the
    /// ribbons' wavelengths scale with its diagonal, which they run along. Scaling a view scales the
    /// whole layout with it, so a launch image aspect-filling a screen of its shape matches the app.
    public struct Layout: Equatable, Sendable {
        /// Half the length of every path: past the view's edge in every direction.
        public var reach: Double
        /// The tint runs between these two, across the ribbons.
        public var tint: ClosedRange<Double>
        /// Each ribbon's top edge at rest, top left first.
        public var offsets: [Double]
        /// How far an edge rolls up and down with the beat.
        public var amplitude: Double
        /// Each ribbon's wavelength along its length.
        public var wavelengths: [Double]
        /// How far below its edge a ribbon fades to nothing.
        public var fade: Double
        /// The blur over the ribbons, in the view's points.
        public var blur: Double

        public init(size: CGSize) {
            let reference = SpaceWashPainter.referenceSize
            let scale = Self.across(size) / Self.across(reference)
            // The design's own unit, its diagonal, scaled to this view.
            let unit = hypot(reference.width, reference.height) * scale
            let diagonal = max(hypot(size.width, size.height), 1)
            reach = diagonal
            tint = -unit / 2 ... unit / 2
            offsets = (0..<SpaceWashPainter.ribbons).map { unit * (-0.42 + Double($0) * 0.17) }
            amplitude = reference.width * 0.065 * scale
            wavelengths = (0..<SpaceWashPainter.ribbons).map { diagonal * (1.2 + Double($0) * 0.12) }
            fade = unit * 0.45
            blur = 39 * scale
        }

        /// How far a view reaches across the ribbons: from its upper left corner to its lower right,
        /// measured across the slant.
        public static func across(_ size: CGSize) -> Double {
            size.width * sin(SpaceWashPainter.angle) + size.height * cos(SpaceWashPainter.angle)
        }
    }

    /// Draws the wash filling `size` at `time` seconds from its first frame.
    public static func draw(in context: GraphicsContext, size: CGSize, time: Double, color: RGB, dark: Bool) {
        var context = context
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background(dark: dark).color()))
        let layout = Layout(size: size)
        let reach = layout.reach
        context.translateBy(x: size.width / 2, y: size.height / 2)
        // From here `u` runs along the ribbons and `v` across them.
        context.rotate(by: .radians(-angle))

        // The tint, deeper toward the lower right.
        let tint = Gradient(stops: [.init(color: color.color(opacity: dark ? 0.1 : 0.05), location: 0),
                                    .init(color: color.color(opacity: dark ? 0.22 : 0.12), location: 1)])
        context.fill(Path(CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                     with: .linearGradient(tint, startPoint: CGPoint(x: 0, y: layout.tint.lowerBound),
                                           endPoint: CGPoint(x: 0, y: layout.tint.upperBound)))

        // Lightest at the top left, deepest at the bottom right.
        let tones = dark
            ? [color.mixed(with: .white, by: 0.3), color.mixed(with: .white, by: 0.12), color,
               color.mixed(with: .black, by: 0.15), color.mixed(with: .black, by: 0.3)]
            : [color.mixed(with: .white, by: 0.5), color.mixed(with: .white, by: 0.35), color.mixed(with: .white, by: 0.2),
               color.mixed(with: .white, by: 0.1), color]
        let opacity = dark ? 0.22 : 0.14
        // The same number of points along every edge, whatever the size.
        let step = reach / 160
        // The blur is given in the view's points, so the layer is left unscaled.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: layout.blur))
            for (index, tone) in tones.enumerated() {
                let band = Double(index)
                // Each ribbon is the fill below a wavy edge, fading out over the next ribbons down.
                let offset = layout.offsets[index]
                let amplitude = layout.amplitude
                let wavelength = layout.wavelengths[index]
                let lag = band * 0.09
                func edge(_ u: Double) -> Double {
                    offset + amplitude * beat(time / period - u / wavelength - lag)
                        + amplitude * 0.25 * sin(u / wavelength * 4 + time * 0.3 + band)
                }
                var path = Path()
                path.move(to: CGPoint(x: -reach, y: reach))
                for u in stride(from: -reach, through: reach, by: step) {
                    path.addLine(to: CGPoint(x: u, y: edge(u)))
                }
                path.addLine(to: CGPoint(x: reach, y: reach))
                path.closeSubpath()
                let fade = Gradient(stops: [.init(color: tone.color(opacity: opacity), location: 0),
                                            .init(color: tone.color(opacity: opacity * 0.45), location: 0.5),
                                            .init(color: tone.color(opacity: 0), location: 1)])
                layer.fill(path, with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: offset - amplitude),
                                                       endPoint: CGPoint(x: 0, y: offset + layout.fade)))
            }
        }
    }

    /// Where a beat is, from 1 (up) through -1 (down) and back, at `phase` beats in: down in the push,
    /// back up through the recovery, smoothly at both turns.
    private static func beat(_ phase: Double) -> Double {
        let phase = phase - phase.rounded(.down)
        return phase < push
            ? cos(.pi * phase / push)
            : -cos(.pi * (phase - push) / (1 - push))
    }
}
