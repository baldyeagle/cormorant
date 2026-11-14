// Renders the launch screen's wash: `SpaceWashPainter` at time zero in its launch color, light and
// dark, into the LaunchWash image set. At 2x: it's all soft, so a 3x screen loses nothing. Built
// together with the painter, from the repo root:
//
//   swiftc -parse-as-library -o /tmp/make-launch-wash assets/brand/make-launch-wash.swift \
//       apps/ios/Cormorant/Support/SpaceWashPainter.swift
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
        let size = SpaceWashPainter.referenceSize
        for (dark, name) in [(false, "LaunchWash.png"), (true, "LaunchWash-Dark.png")] {
            let canvas = Canvas { context, size in
                SpaceWashPainter.draw(in: context, size: size, time: 0,
                                      color: SpaceWashPainter.launchColor(dark: dark), dark: dark)
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            guard let image = renderer.cgImage.map(opaque) else { fatalError("nothing rendered") }
            let url = outDir.appending(path: name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { fatalError("can't write \(url.path)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
            print("wrote", name, image.width, "x", image.height)
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
