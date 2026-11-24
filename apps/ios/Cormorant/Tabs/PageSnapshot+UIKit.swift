import UIKit

extension PageSnapshot {
    /// Splits a picture of a whole web view `height` points tall, `band` points from its top.
    init?(_ image: UIImage, band: CGFloat, of height: CGFloat) {
        guard let cgImage = image.cgImage else { return nil }
        self.init(cgImage, scale: image.scale, band: band, of: height)
    }
}
