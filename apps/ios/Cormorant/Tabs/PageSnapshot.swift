import CoreGraphics
import WebKit

/// A tab's page as last pictured, split where the status bar ends. Cards show the page's content, as
/// Safari's do; where the page runs under the status bar, the band behind it is kept apart for what
/// lands on the page (a card growing into it, the back swipe's underlay) to draw there, so the page's
/// fixed header or content carried up behind the clock arrives with it.
struct PageSnapshot {
    let content: CGImage
    /// Nil where the page doesn't run under a status bar along the top.
    let statusBand: CGImage?
    let scale: CGFloat

    init(content: CGImage, statusBand: CGImage?, scale: CGFloat) {
        self.content = content
        self.statusBand = statusBand
        self.scale = scale
    }

    /// Splits a picture of a whole web view `height` points tall, `band` points from its top.
    init(_ image: CGImage, scale: CGFloat, band: CGFloat, of height: CGFloat) {
        self.scale = scale
        let rows = height > 0 ? Int((band / height * CGFloat(image.height)).rounded()) : 0
        guard rows > 0, rows < image.height,
              let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows)),
              let rest = image.cropping(to: CGRect(x: 0, y: rows, width: image.width, height: image.height - rows))
        else {
            content = image
            statusBand = nil
            return
        }
        content = rest
        statusBand = top
    }
}

extension PageSnapshot {
    /// Without the status band: for a page that no longer runs under the status bar.
    var contentOnly: PageSnapshot { PageSnapshot(content: content, statusBand: nil, scale: scale) }
}

extension WKWebView {
    /// `takeSnapshot(configuration:)` as a CGImage and its scale. WebKit returns a UIImage on iOS and an
    /// NSImage on the Mac.
    func snapshotImage(configuration: WKSnapshotConfiguration) async throws -> (image: CGImage, scale: CGFloat)? {
        let image = try await takeSnapshot(configuration: configuration)
        #if canImport(UIKit)
        return image.cgImage.map { ($0, image.scale) }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0
        else { return nil }
        return (cgImage, CGFloat(cgImage.width) / image.size.width)
        #endif
    }
}
