import CormorantCore
import SwiftUI
import UIKit
import WebKit

/// What a tab's page offers the status-bar strip, as last settled.
struct PageColors: Equatable {
    /// `<meta name="theme-color">`, as WebKit resolved it for the current appearance.
    var theme: UIColor?
    /// The color WebKit draws under the page. Nil until a page has committed: before that it's only
    /// the web view's own background.
    var underPage: UIColor?
    /// What's along the top edge of the page on screen.
    var topEdge: TopEdgeSample?
    /// The history item these belong to.
    var item: WKBackForwardListItem?
    /// The appearance they were read in; theme colors (media queries) and the page differ by it.
    var style: UIUserInterfaceStyle = .unspecified
    /// Show the change as a fade (the page changed in place); false for a page's first colors and
    /// for colors that come back with the page (back or forward to a page seen before), which cut.
    var fades = true

    static func == (lhs: PageColors, rhs: PageColors) -> Bool {
        lhs.theme == rhs.theme && lhs.underPage == rhs.underPage && lhs.topEdge == rhs.topEdge
            && lhs.item === rhs.item && lhs.style == rhs.style && lhs.fades == rhs.fades
    }
}

extension WKBackForwardListItem {
    private static var pageColorsKey: UInt8 = 0

    /// The colors last read for this page, for going back or forward to it. Must not reference the
    /// item (a cycle would keep it alive).
    var pageColors: PageColors? {
        get { (objc_getAssociatedObject(self, &Self.pageColorsKey) as? Box)?.colors }
        set { objc_setAssociatedObject(self, &Self.pageColorsKey, newValue.map(Box.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private final class Box {
        let colors: PageColors
        init(_ colors: PageColors) { self.colors = colors }
    }
}

extension TabSession {
    /// The page's colors were read in the other appearance (it just switched) and are being re-read.
    func pageColorsAreStale(in colorScheme: ColorScheme) -> Bool {
        pageColors.style != .unspecified && pageColors.style != (colorScheme == .dark ? .dark : .light)
    }

    /// The status-bar strip's tint for this tab's page in `colorScheme`, or nil for the default.
    func chromeTint(in colorScheme: ColorScheme) -> ChromeTint? {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        guard !pageColorsAreStale(in: colorScheme) else { return nil }
        return ChromeTint(themeColor: RGBColor(pageColors.theme, in: traits),
                          pageBackground: RGBColor(pageColors.underPage, in: traits),
                          topEdge: pageColors.topEdge,
                          defaultBackground: .launchBackground(in: colorScheme),
                          isDark: colorScheme == .dark)
    }
}

extension RGBColor {
    /// `color` resolved for `traits`, in (extended) sRGB.
    init?(_ color: UIColor?, in traits: UITraitCollection) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard let color, color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return nil }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The default chrome: Vialumi's white, or #030712 in dark mode.
    static func launchBackground(in colorScheme: ColorScheme) -> RGBColor {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return RGBColor(UIColor(resource: .launchBackground), in: traits) ?? .white
    }
}

extension Color {
    init(_ color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension ChromeTint {
    /// The scheme whose system foregrounds (the status bar) read on the tint.
    var colorScheme: ColorScheme {
        foreground == .light ? .dark : .light
    }

    /// This tint if the strip can show it. Before iOS 27 the status bar's style follows the system
    /// appearance, so a tint that needs the other one would hide the clock; the strip keeps the
    /// default there.
    func drawable(in colorScheme: ColorScheme) -> ChromeTint? {
        if #available(iOS 27, *) { return self }
        return self.colorScheme == colorScheme ? self : nil
    }
}

extension BrowserStore {
    /// The site's color for the status-bar strip, or nil for the default. Only over a page: not the
    /// empty state or a load error, which draw their own backgrounds.
    func stripTint(in colorScheme: ColorScheme) -> ChromeTint? {
        guard settings.tintsChrome, activeTab?.url != nil,
              let session = activeSession, session.loadError == nil else { return nil }
        return session.chromeTint(in: colorScheme)?.drawable(in: colorScheme)
    }

    /// What the strip shows for the active tab, for anything that has to match it (the switcher's
    /// card growing into the page fades a backdrop of this color in behind it).
    func stripColor(in colorScheme: ColorScheme) -> Color {
        Color(stripTint(in: colorScheme)?.background ?? .launchBackground(in: colorScheme))
    }

    /// `stripColor(in:)` for UIKit callers.
    func stripUIColor(for style: UIUserInterfaceStyle) -> UIColor {
        let colorScheme: ColorScheme = style == .dark ? .dark : .light
        let color = stripTint(in: colorScheme)?.background ?? .launchBackground(in: colorScheme)
        return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

extension UIImage {
    /// The top `height` points (of this image) drawn `width` points wide (at 3x), as a top-edge sample
    /// from its first and last rows: the same sample the strip takes of a live page.
    func topEdgeSample(height: CGFloat, width: CGFloat) -> TopEdgeSample? {
        guard size.width > 0, size.height >= height, height > 0, let image = cgImage,
              // Only the band itself, so nothing below it is filtered into its rows.
              let band = image.cropping(to: CGRect(x: 0, y: 0, width: image.width,
                                                   height: max(1, Int((height * scale).rounded()))))
        else { return nil }
        let pixels = CGSize(width: (width * 3).rounded(), height: 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            UIImage(cgImage: band).draw(in: CGRect(origin: .zero, size: pixels))
        }
        let rows = drawn.sRGBRows()
        guard let edge = rows.first, let below = rows.last else { return nil }
        return TopEdgeSample(rows: [edge, below])
    }

    /// Every pixel, in sRGB, row by row from the top. For small images: a snapshot of a page's edge.
    func sRGBRows() -> [[RGBColor]] {
        guard let image = cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        return (0..<height).map { y in
            (0..<width).map { x in
                let i = (y * width + x) * 4
                return RGBColor(red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255, blue: Double(bytes[i + 2]) / 255)
            }
        }
    }
}
