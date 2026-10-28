import OSLog
import UIKit

extension Logger {
    nonisolated static let app = Logger(subsystem: "dev.baldyeagle.cormorant", category: "app")
}

extension UIView {
    /// The frontmost view controller in this view's window scene that can present an alert, or nil
    /// when the view is off-screen, its scene is in the background, or an alert is already up.
    var alertPresenter: UIViewController? {
        guard let window, let scene = window.windowScene, scene.activationState != .background else { return nil }
        var controller = (scene.keyWindow ?? window).rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        guard let controller, !(controller is UIAlertController) else { return nil }
        return controller
    }
}
