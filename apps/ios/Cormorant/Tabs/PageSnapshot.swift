import UIKit

/// A tab's page as last pictured, split where the status bar ends. Cards show the page's content, as
/// Safari's do; where the page runs under the status bar, the band behind it is kept apart for what
/// lands on the page (a card growing into it, the back swipe's underlay) to draw there, so the page's
/// fixed header or content carried up behind the clock arrives with it.
struct PageSnapshot {
    let content: UIImage
    /// Nil where the page doesn't run under a status bar along the top.
    let statusBand: UIImage?

    init(content: UIImage, statusBand: UIImage?) {
        self.content = content
        self.statusBand = statusBand
    }

    /// Splits a picture of a whole web view `height` points tall, `band` points from its top.
    init(_ image: UIImage, band: CGFloat, of height: CGFloat) {
        let rows = height > 0 ? Int((band / height * CGFloat(image.cgImage?.height ?? 0)).rounded()) : 0
        guard let full = image.cgImage, rows > 0, rows < full.height,
              let top = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: rows)),
              let rest = full.cropping(to: CGRect(x: 0, y: rows, width: full.width, height: full.height - rows))
        else {
            content = image
            statusBand = nil
            return
        }
        content = UIImage(cgImage: rest, scale: image.scale, orientation: image.imageOrientation)
        statusBand = UIImage(cgImage: top, scale: image.scale, orientation: image.imageOrientation)
    }
}

extension PageSnapshot {
    /// Without the status band: for a page that no longer runs under the status bar.
    var contentOnly: PageSnapshot { PageSnapshot(content: content, statusBand: nil) }
}
