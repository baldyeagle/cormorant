import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let srcPath = args[1], outDir = args[2]

func load(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
func save(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote", name, img.width, "x", img.height)
}
func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// 1. key out white -> transparent, recover edge colors. Returns image + alpha bbox.
let src = load(srcPath)
let w = src.width, h = src.height
let ctx = rgbaContext(w, h)
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
let rgb = (0..<(w * h * 3)).map { Double(p[$0 / 3 * 4 + $0 % 3]) / 255 }
func channel(_ x: Int, _ y: Int, _ c: Int) -> Double { rgb[(y * w + x) * 3 + c] }
func darkest(_ x: Int, _ y: Int) -> Int { (0..<3).min { channel(x, y, $0) < channel(x, y, $1) }! }
// pure white -> 0, anything with a channel below ~0.82 -> 1
var alpha = [Double](repeating: 0, count: w * h)
for y in 6..<(h - 6) { for x in 6..<(w - 6) {   // the outer 6px are edge artifacts in the source
    alpha[y * w + x] = max(0, min(1, (1 - channel(x, y, darkest(x, y))) / 0.18))
}}
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    var a = alpha[y * w + x]
    // Pixels on the silhouette's edge are part bird, part white. The 0.18 ramp above calls most of
    // them opaque, which keeps their white and shows as a light outline on a dark background.
    // Re-estimate their alpha against the darkest opaque pixel nearby, standing in for the bird's color.
    // Only pixels near the background (alpha < 0.1) count, so light patches inside the bird (the beak) stay solid.
    let onEdge = a > 0 && (-2...2).contains { dy in (-2...2).contains { dx in alpha[(y + dy) * w + x + dx] < 0.1 } }
    if onEdge {
        var best: (x: Int, y: Int)? = nil
        for dy in -3...3 { for dx in -3...3 where alpha[(y + dy) * w + x + dx] == 1 {
            let (nx, ny) = (x + dx, y + dy)
            if best == nil || channel(nx, ny, darkest(nx, ny)) < channel(best!.x, best!.y, darkest(best!.x, best!.y)) { best = (nx, ny) }
        }}
        // Thin feather tips can have no solid pixel nearby; the plumage is near-black, so assume that.
        let c = darkest(x, y), f = best.map { channel($0.x, $0.y, c) } ?? 0.15
        a = min(a, max(0, min(1, (1 - channel(x, y, c)) / (1 - f))))
    }
    if a < 0.02 { p[i] = 0; p[i+1] = 0; p[i+2] = 0; p[i+3] = 0; continue }
    // un-blend from white, then premultiply
    func un(_ c: Double) -> Double { max(0, min(1, (c - (1 - a)) / a)) }
    p[i]   = UInt8((un(channel(x, y, 0)) * a * 255).rounded())
    p[i+1] = UInt8((un(channel(x, y, 1)) * a * 255).rounded())
    p[i+2] = UInt8((un(channel(x, y, 2)) * a * 255).rounded())
    p[i+3] = UInt8((a * 255).rounded())
    if a > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}}
let cut = ctx.makeImage()!
save(cut, "cormorant-head.png")
// note: CG coordinates are bottom-up in the context but the bitmap rows we iterated are top-down relative to draw; bbox is in bitmap space
let bbox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
print("alpha bbox (bitmap space):", bbox)
let subject = cut.cropping(to: bbox)!   // cropping uses top-left origin for bitmap-backed images
save(subject, "cormorant-head-cropped.png")

// 2. compose into a square tile
func tile(_ size: Int, bg: (Double, Double, Double)?, scale: Double, grayscale: Bool = false, name: String) {
    let c = rgbaContext(size, size)
    if let bg = bg {
        c.setFillColor(CGColor(srgbRed: bg.0, green: bg.1, blue: bg.2, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    let sw = Double(subject.width), sh = Double(subject.height)
    let fit = Double(size) * scale
    let s = min(fit / sw, fit / sh)
    let dw = sw * s, dh = sh * s
    let rect = CGRect(x: (Double(size) - dw) / 2, y: (Double(size) - dh) / 2, width: dw, height: dh)
    c.interpolationQuality = .high
    c.draw(subject, in: rect)
    var img = c.makeImage()!
    if grayscale {
        let g = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // draw onto white gray to get luminance, then reuse the color image's alpha as a mask
        g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: size, height: size))
        g.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        let lum = g.makeImage()!
        // build RGBA from luminance + original alpha
        let o = rgbaContext(size, size)
        o.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        let op = o.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        let lc = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        lc.draw(lum, in: CGRect(x: 0, y: 0, width: size, height: size))
        let lp = lc.data!.bindMemory(to: UInt8.self, capacity: size * size)
        for i in 0..<(size * size) {
            let a = Double(op[i*4+3]) / 255
            let v = Double(lp[i]) / 255
            let un = a > 0 ? max(0, min(1, (v - (1 - a)) / a)) : 0
            let pm = UInt8((un * a * 255).rounded())
            op[i*4] = pm; op[i*4+1] = pm; op[i*4+2] = pm
        }
        img = o.makeImage()!
    }
    if bg != nil {
        // App Store icons must not have an alpha channel.
        let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        opaque.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        img = opaque.makeImage()!
    }
    save(img, name)
}
// Vialumi's background tokens (packages/ui theme.css): oklch(1 0 0) and oklch(0.13 0.028 261.692),
// i.e. white and Tailwind gray-950. The app's LaunchBackground color uses the same pair.
let light = (1.0, 1.0, 1.0)
let dark = (0x03/255.0, 0x07/255.0, 0x12/255.0)
tile(1024, bg: light, scale: 0.78, name: "AppIcon.png")
tile(1024, bg: dark,  scale: 0.78, name: "AppIcon-dark.png")
tile(1024, bg: nil,   scale: 0.78, grayscale: true, name: "AppIcon-tinted.png")
tile(180, bg: light, scale: 0.82, name: "apple-touch-icon.png")
tile(64,  bg: nil,  scale: 0.96, name: "favicon-64.png")
tile(32,  bg: nil,  scale: 1.0,  name: "favicon-32.png")
tile(512, bg: nil,  scale: 0.9,  name: "cormorant-mark-512.png")
// The launch screen and the blank tab: one 128pt mark, so the launch image hands off to the tab in place.
tile(128, bg: nil, scale: 0.9, name: "CormorantMark.png")
tile(256, bg: nil, scale: 0.9, name: "CormorantMark@2x.png")
tile(384, bg: nil, scale: 0.9, name: "CormorantMark@3x.png")
