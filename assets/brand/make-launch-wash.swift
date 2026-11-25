// Renders the launch screen's wash: `SpaceWashPainter` at time zero in its launch color, light and
// dark, into the LaunchWash image set, in each shape the launch screen comes in. The launch screen
// aspect-fills it, and the wash's layout scales with its view, so on a screen of an image's shape the
// launch screen and the app's first frame are the same picture:
// - an iPhone in portrait (the default), at the painter's `referenceSize`;
// - an iPhone in landscape (compact height);
// - an iPad, either way up. Its launch screen can't tell portrait from landscape, so its image is a
//   shape between the two (about 9:8): aspect-filled, its ribbons come out 10-17% larger than the
//   app's either way up, rather than right one way and 30-60% off the other.
// At 2x: it's all soft, so a 3x screen loses nothing; the iPad's is drawn smaller, which scales the
// same picture down. Built together with the painter, from the repo root:
//
//   swiftc -parse-as-library -o /tmp/make-launch-wash assets/brand/make-launch-wash.swift \
//       packages/CormorantKit/Sources/CormorantBrowser/Wash/SpaceWashPainter.swift
//   /tmp/make-launch-wash apps/ios/Cormorant/Assets.xcassets/LaunchWash.imageset
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct MakeLaunchWash {
    @MainActor
    static func main() {
        let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
        let shapes: [(name: String, size: CGSize)] = [
            ("LaunchWash", SpaceWashPainter.referenceSize),
            ("LaunchWash-Landscape", CGSize(width: 874, height: 402)),
            ("LaunchWash-iPad", CGSize(width: 560, height: 500)),
        ]
        for shape in shapes {
            for dark in [false, true] {
                let canvas = Canvas { context, size in
                    SpaceWashPainter.draw(in: context, size: size, time: 0,
                                          color: SpaceWashPainter.launchColor(dark: dark), dark: dark)
                }
                .frame(width: shape.size.width, height: shape.size.height)
                let renderer = ImageRenderer(content: canvas)
                renderer.scale = 2
                guard let image = renderer.cgImage.map(opaque) else { fatalError("nothing rendered") }
                let name = shape.name + (dark ? "-Dark" : "") + ".png"
                let url = outDir.appending(path: name)
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { fatalError("can't write \(url.path)") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
                print("wrote", name, image.width, "x", image.height)
            }
        }
    }

    /// `image` without its alpha channel (the wash fills it), in sRGB.
    private static func opaque(_ image: CGImage) -> CGImage {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }
}
