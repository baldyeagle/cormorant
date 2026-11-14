import SwiftUI

/// The Space's color washed across the screen: five broad diagonal ribbons, lower left to upper right,
/// blended into a tint of the whole screen. They roll to a wingbeat's rhythm, a quicker push and then a
/// long, slow recovery, each ribbon a little behind the one before; nothing in it is drawn as a bird.
/// `SpaceWash` draws it live.
///
/// Drawn on a fixed portrait canvas, `referenceSize`, scaled to fill whatever it's given. The launch
/// screen is this drawing at time zero in `launchColor`, filling the screen the same way
/// (`assets/brand/make-launch-wash.swift` renders it), so the app's first frame is the same picture.
/// Portable (SwiftUI only, no UIKit) so that script can build it on the Mac.
nonisolated enum SpaceWashPainter {
    /// An sRGB color, from a Space's `Swatch` or one of the fixed ones here.
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        /// `self` moved `fraction` of the way to `other`.
        func mixed(with other: RGB, by fraction: Double) -> RGB {
            RGB(red: red + (other.red - red) * fraction,
                green: green + (other.green - green) * fraction,
                blue: blue + (other.blue - blue) * fraction)
        }

        func color(opacity: Double = 1) -> Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
        }

        static let white = RGB(red: 1, green: 1, blue: 1)
        static let black = RGB(red: 0, green: 0, blue: 0)
    }

    /// The canvas everything is laid out on (an iPhone 17 Pro's screen, in points); scaled to fill.
    static let referenceSize = CGSize(width: 402, height: 874)
    /// One beat, in seconds.
    static let period = 5.5
    /// The share of a beat its push takes; the recovery takes the rest.
    private static let push = 0.35

    /// The launch screen's color: the launch screen can't know the Space, so it has the brand's cyan,
    /// and the app moves it to the Space's once it runs. `BrandCyan` is Display P3, past what sRGB holds;
    /// this is the nearest sRGB color to it. At the few percent the wash uses it, the difference is slight.
    static func launchColor(dark: Bool) -> RGB {
        dark ? RGB(red: 0, green: 0.872, blue: 0.878) : RGB(red: 0, green: 0.572, blue: 0.59)
    }

    /// What it's drawn on: Vialumi's white, or #030712 (`LaunchBackground`).
    static func background(dark: Bool) -> RGB {
        dark ? RGB(red: 3 / 255, green: 7 / 255, blue: 18 / 255) : .white
    }

    /// Draws the wash filling `size` at `time` seconds from its first frame.
    static func draw(in context: GraphicsContext, size: CGSize, time: Double, color: RGB, dark: Bool) {
        var context = context
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background(dark: dark).color()))
        let width = referenceSize.width
        let diagonal = hypot(referenceSize.width, referenceSize.height)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        let scale = max(size.width / referenceSize.width, size.height / referenceSize.height)
        context.scaleBy(x: scale, y: scale)
        // About 30° up from horizontal; from here `u` runs along the ribbons and `v` across them.
        context.rotate(by: .radians(-0.5))

        // The tint, deeper toward the lower right.
        let tint = Gradient(stops: [.init(color: color.color(opacity: dark ? 0.1 : 0.05), location: 0),
                                    .init(color: color.color(opacity: dark ? 0.22 : 0.12), location: 1)])
        context.fill(Path(CGRect(x: -diagonal, y: -diagonal, width: 2 * diagonal, height: 2 * diagonal)),
                     with: .linearGradient(tint, startPoint: CGPoint(x: 0, y: -diagonal / 2),
                                           endPoint: CGPoint(x: 0, y: diagonal / 2)))

        // Lightest at the top left, deepest at the bottom right.
        let tones = dark
            ? [color.mixed(with: .white, by: 0.3), color.mixed(with: .white, by: 0.12), color,
               color.mixed(with: .black, by: 0.15), color.mixed(with: .black, by: 0.3)]
            : [color.mixed(with: .white, by: 0.5), color.mixed(with: .white, by: 0.35), color.mixed(with: .white, by: 0.2),
               color.mixed(with: .white, by: 0.1), color]
        let opacity = dark ? 0.22 : 0.14
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 39))
            for (index, tone) in tones.enumerated() {
                let band = Double(index)
                // Each ribbon is the fill below a wavy edge, fading out over the next ribbons down.
                let offset = diagonal * (-0.42 + band * 0.17)
                let amplitude = width * 0.065
                let wavelength = diagonal * (1.2 + band * 0.12)
                let lag = band * 0.09
                func edge(_ u: Double) -> Double {
                    offset + amplitude * beat(time / period - u / wavelength - lag)
                        + amplitude * 0.25 * sin(u / wavelength * 4 + time * 0.3 + band)
                }
                var path = Path()
                path.move(to: CGPoint(x: -diagonal, y: diagonal))
                for u in stride(from: -diagonal, through: diagonal, by: 6) {
                    path.addLine(to: CGPoint(x: u, y: edge(u)))
                }
                path.addLine(to: CGPoint(x: diagonal, y: diagonal))
                path.closeSubpath()
                let fade = Gradient(stops: [.init(color: tone.color(opacity: opacity), location: 0),
                                            .init(color: tone.color(opacity: opacity * 0.45), location: 0.5),
                                            .init(color: tone.color(opacity: 0), location: 1)])
                layer.fill(path, with: .linearGradient(fade, startPoint: CGPoint(x: 0, y: offset - amplitude),
                                                       endPoint: CGPoint(x: 0, y: offset + diagonal * 0.45)))
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
