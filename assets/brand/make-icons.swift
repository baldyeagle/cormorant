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
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    let r = Double(p[i]) / 255, g = Double(p[i+1]) / 255, b = Double(p[i+2]) / 255
    let lo = min(r, g, b)
    var a = (1 - lo) / 0.18
    if x < 6 || x >= w - 6 || y < 6 || y >= h - 6 { a = 0 }   // drop edge artifacts in the source          // pure white -> 0, anything with a channel below ~0.82 -> 1
    a = max(0, min(1, a))
    if a < 0.02 { p[i] = 0; p[i+1] = 0; p[i+2] = 0; p[i+3] = 0; continue }
    // un-blend from white, then premultiply
    func un(_ c: Double) -> Double { max(0, min(1, (c - (1 - a)) / a)) }
    p[i]   = UInt8((un(r) * a * 255).rounded())
    p[i+1] = UInt8((un(g) * a * 255).rounded())
    p[i+2] = UInt8((un(b) * a * 255).rounded())
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
    save(img, name)
}
let pane = (0xf7/255.0, 0xf9/255.0, 0xf9/255.0)
let slate = (0x17/255.0, 0x23/255.0, 0x27/255.0)
tile(1024, bg: pane,  scale: 0.78, name: "AppIcon.png")
tile(1024, bg: slate, scale: 0.78, name: "AppIcon-dark.png")
tile(1024, bg: nil,   scale: 0.78, grayscale: true, name: "AppIcon-tinted.png")
tile(180, bg: pane, scale: 0.82, name: "apple-touch-icon.png")
tile(64,  bg: nil,  scale: 0.96, name: "favicon-64.png")
tile(32,  bg: nil,  scale: 1.0,  name: "favicon-32.png")
tile(512, bg: nil,  scale: 0.9,  name: "cormorant-mark-512.png")
