import SwiftUI
import WebKit

/// Hosts the active tab's `WKWebView`, swapping it in place when the tab changes.
/// The view extends under the bottom bar; `barHeight` tells WebKit how much of it is covered.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let barHeight: CGFloat

    func makeUIView(context: Context) -> ContainerView {
        ContainerView()
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.host(webView)
        container.barHeight = barHeight
    }

    final class ContainerView: UIView {
        var barHeight: CGFloat = 0 {
            didSet { if barHeight != oldValue { updateBarInsets() } }
        }
        private var webView: WKWebView?

        func host(_ newWebView: WKWebView) {
            guard newWebView !== webView else { return }
            webView?.removeFromSuperview()
            newWebView.frame = bounds
            newWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(newWebView)
            webView = newWebView
            updateBarInsets()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateBarInsets()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            updateBarInsets()
        }

        /// Two insets, because they do different jobs:
        /// - `obscuredContentInsets` shrinks WebKit's layout viewport to the uncovered area, so
        ///   `position: fixed` elements (bottom and top) are laid out above the bar.
        /// - the scroll view's content inset extends the scroll range so the end of the page can
        ///   scroll clear of the bar (UIKit adds the home-indicator safe area on top of it).
        /// The keyboard is left to WebKit.
        private func updateBarInsets() {
            guard let webView else { return }
            let covered = barHeight + safeAreaInsets.bottom
            if webView.obscuredContentInsets.bottom != covered {
                webView.obscuredContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: covered, right: 0)
            }
            let scrollView = webView.scrollView
            if scrollView.contentInset.bottom != barHeight {
                scrollView.contentInset.bottom = barHeight
                scrollView.verticalScrollIndicatorInsets.bottom = barHeight
            }
        }
    }
}
