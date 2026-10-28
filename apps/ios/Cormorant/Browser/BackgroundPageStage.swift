import UIKit
import WebKit

/// The size and insets a tab's web view has on screen. A link preview and a background tab are laid
/// out to match, so a page loaded off screen needs no relayout (no reflow, no moved fixed elements)
/// when it becomes the tab on screen.
struct PageLayout {
    let size: CGSize
    /// Where the web view sits in its window. A background page is staged at the same spot, so its
    /// safe-area insets (status bar, home indicator) match the tab's too.
    let frameInWindow: CGRect
    let obscuredInsets: UIEdgeInsets
    let scrollInsetBottom: CGFloat

    init(of webView: WKWebView) {
        size = webView.bounds.size
        frameInWindow = webView.window.map { webView.convert(webView.bounds, to: $0) }
            ?? CGRect(origin: .zero, size: webView.bounds.size)
        obscuredInsets = webView.obscuredContentInsets
        scrollInsetBottom = webView.scrollView.contentInset.bottom
    }

    /// Sizes `webView` (at the origin, no transform) and gives it the on-screen insets.
    func apply(to webView: WKWebView) {
        webView.transform = .identity
        webView.frame = CGRect(origin: .zero, size: size)
        webView.obscuredContentInsets = obscuredInsets
        webView.scrollView.contentInset.bottom = scrollInsetBottom
        webView.scrollView.verticalScrollIndicatorInsets.bottom = scrollInsetBottom
    }
}

/// Where background tabs load. WebKit only lays out and paints a web view that is in a window, and a
/// snapshot for the tab switcher needs a painted page, so a background tab's web view sits here until
/// its page has loaded and been snapshotted. The stage is a direct subview of the window behind the
/// root view: never touchable, hidden from accessibility, and (unlike anything inside the root view)
/// still in the window while a full-screen cover such as the tab switcher is up. An opaque curtain
/// over the pages keeps them out of sight even where the root view doesn't cover the window (a sheet
/// shrinking it, say); WebKit doesn't count being covered as hidden, so they still paint.
@MainActor
final class BackgroundPageStage {
    private var container: UIView?
    private var curtain: UIView?

    func add(_ webView: WKWebView, layout: PageLayout, in window: UIWindow) {
        let container = container(in: window)
        layout.apply(to: webView)
        webView.frame = container.convert(layout.frameInWindow, from: window)
        container.addSubview(webView)
        if let curtain { container.bringSubviewToFront(curtain) }
        window.sendSubviewToBack(container)
    }

    /// Takes `webView` off the stage, unless something else (the tab's on-screen container) already has.
    func remove(_ webView: WKWebView) {
        guard let container, webView.superview === container else { return }
        webView.removeFromSuperview()
    }

    private func container(in window: UIWindow) -> UIView {
        if let container, container.window === window { return container }
        container?.removeFromSuperview()
        let view = UIView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.clipsToBounds = true
        let curtain = UIView(frame: view.bounds)
        curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curtain.backgroundColor = .black
        view.addSubview(curtain)
        window.insertSubview(view, at: 0)
        container = view
        self.curtain = curtain
        return view
    }
}
