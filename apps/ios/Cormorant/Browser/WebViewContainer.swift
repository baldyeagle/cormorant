import SwiftUI
import WebKit

/// Hosts the active tab's `WKWebView`, swapping it in place when the tab changes.
/// The view extends under the bottom bar; `barHeight` tells WebKit how much of it is covered.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let barHeight: CGFloat
    /// Set for a tab a link opened: swiping in from the left edge on its first page closes it.
    var backSwipeClose: BackSwipeClose?

    /// Arc's back-to-close. Read when a swipe starts, so a swipe finishes with the tab it began on.
    struct BackSwipeClose {
        /// The tab the close lands on, shown under the page as it slides away. Nil shows a blank page.
        let destinationSnapshot: () -> UIImage?
        let close: () -> Void
    }

    func makeUIView(context: Context) -> ContainerView {
        ContainerView()
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.backSwipeClose = backSwipeClose
        container.host(webView)
        container.barHeight = barHeight
    }

    final class ContainerView: UIView, UIGestureRecognizerDelegate {
        var barHeight: CGFloat = 0 {
            didSet { if barHeight != oldValue { updateBarInsets() } }
        }
        var backSwipeClose: BackSwipeClose?
        private var webView: WKWebView?
        private let edgePan = UIScreenEdgePanGestureRecognizer()
        /// The swipe in progress, or a committed one waiting for the destination's web view.
        private var swipe: BackSwipe?
        /// A committed swipe whose snapshot is still fading off the destination.
        private var fading: BackSwipe?
        /// A tab opened from a tapped link preview, growing from the preview's card over the page it
        /// was opened from. It becomes the hosted web view when the animation ends.
        private var expansion: (webView: WKWebView, card: UIView, animator: UIViewPropertyAnimator)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            edgePan.edges = .left
            edgePan.delegate = self
            edgePan.addTarget(self, action: #selector(didEdgePan(_:)))
            addGestureRecognizer(edgePan)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func host(_ newWebView: WKWebView) {
            if let expansion {
                // The new tab's web view lands when its animation ends; anything else cuts it short.
                if expansion.webView === newWebView { return }
                finishExpansion()
            }
            guard newWebView !== webView else { return }
            let committed = swipe?.isCommitted == true
            if !committed { cancelSwipe() }
            clearFading()
            webView?.removeFromSuperview()
            if let old = webView { BackSwipe.reset(old) }
            newWebView.transform = .identity
            newWebView.frame = bounds
            newWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(newWebView)
            webView = newWebView
            updateBarInsets()
            // The snapshot stays over the destination's web view for a moment, so one that's still
            // painting (or reloading after eviction) doesn't flash blank.
            if committed, let swipe {
                fading = swipe
                // Let go after: it holds the closed tab's web view.
                swipe.fadeOut(over: newWebView, in: self) { [weak self] in
                    if self?.fading === swipe { self?.fading = nil }
                }
            }
            swipe = nil
        }

        /// The snapshot isn't left over another tab, or over a new swipe that would then go unseen.
        private func clearFading() {
            fading?.tearDown()
            fading = nil
        }

        /// Grows `newWebView` (the new tab's, already showing its page at this container's size) from a
        /// link preview's card to fill the container, like the card scaling up into the page. Call
        /// before the tab switch reaches `host(_:)`. With Reduce Motion it fades in where it will rest.
        func expand(_ newWebView: WKWebView, from card: LinkPreviewHandoff.Card) {
            finishExpansion()
            // A back swipe can't be under way (the menu was up); nothing of one is left over the page.
            cancelSwipe()
            clearFading()
            guard let window, bounds.width > 0 else {
                host(newWebView)
                return
            }
            let cardView = UIView(frame: convert(card.frame, from: window))
            cardView.clipsToBounds = true
            cardView.layer.cornerRadius = card.cornerRadius
            cardView.layer.cornerCurve = .continuous
            cardView.backgroundColor = newWebView.underPageBackgroundColor
            // The page at full size, shrunk to the card as the preview showed it.
            newWebView.autoresizingMask = []
            newWebView.transform = .identity
            newWebView.bounds = CGRect(origin: .zero, size: bounds.size)
            newWebView.transform = CGAffineTransform(scaleX: card.scale, y: card.scale)
            newWebView.center = CGPoint(x: bounds.width * card.scale / 2, y: bounds.height * card.scale / 2)
            cardView.addSubview(newWebView)
            addSubview(cardView)
            let rest = { [bounds] in
                cardView.frame = bounds
                cardView.layer.cornerRadius = 0
                newWebView.transform = .identity
                newWebView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            let animator: UIViewPropertyAnimator
            if UIAccessibility.isReduceMotionEnabled {
                rest()
                cardView.alpha = 0
                animator = UIViewPropertyAnimator(duration: 0.25, curve: .easeOut) { cardView.alpha = 1 }
            } else {
                // No bounce, like the switcher's card growing into a page: it lands exactly on the page.
                animator = UIViewPropertyAnimator(duration: 0.4, dampingRatio: 1, animations: rest)
            }
            animator.addCompletion { [weak self] _ in self?.finishExpansion() }
            expansion = (newWebView, cardView, animator)
            animator.startAnimation()
        }

        /// Ends an expansion where it is (or where it ended) and hosts its web view.
        private func finishExpansion() {
            guard let expansion else { return }
            self.expansion = nil
            if expansion.animator.state == .active { expansion.animator.stopAnimation(true) }
            // Moved straight into this view (never out of the window, which WebKit would treat as the
            // page being hidden), then the empty card goes.
            host(expansion.webView)
            expansion.card.removeFromSuperview()
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

        // MARK: Back swipe to close

        /// Only from the first page: with history, WebKit's own back swipe takes the edge.
        private var canBackSwipeClose: Bool {
            backSwipeClose != nil && webView?.canGoBack == false && swipe == nil && expansion == nil
        }

        /// UIView's own, which is also the delegate method.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === edgePan ? canBackSwipeClose : super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        /// A page that scrolls sideways, or a sideways scroller in it (its own scroll view), would
        /// otherwise take a swipe that starts at the edge.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === edgePan, other is UIPanGestureRecognizer, let webView,
                  let scrollView = other.view as? UIScrollView, scrollView.isDescendant(of: webView)
            else { return false }
            return canBackSwipeClose
        }

        @objc private func didEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
            switch pan.state {
            case .began:
                guard let webView, let backSwipeClose else { return }
                clearFading()
                swipe = BackSwipe(webView: webView, in: self, snapshot: backSwipeClose.destinationSnapshot(),
                                  close: backSwipeClose.close)
            case .changed:
                swipe?.track(pan.translation(in: self).x)
            case .ended, .cancelled, .failed:
                guard let swipe, !swipe.isCommitted else { return }
                let velocity = pan.velocity(in: self).x
                let progress = pan.translation(in: self).x / max(bounds.width, 1)
                // A flick counts, but not a twitch at the edge.
                let flicked = velocity > 700 && progress > 0.1
                // Not if the page added history mid-swipe (`pushState`): the tab can go back now.
                let commits = pan.state == .ended && (progress > 0.35 && velocity > -200 || flicked)
                    && webView?.canGoBack == false
                if commits {
                    // The swipe is passed along: a tab switch mid-animation clears `self.swipe`, and the
                    // tab must still close.
                    swipe.commit { [weak self] in self?.swipeDidCommit(swipe) }
                } else {
                    swipe.cancel { [weak self] in
                        if self?.swipe === swipe { self?.swipe = nil }
                    }
                }
            default:
                break
            }
        }

        /// The page is off screen: close the tab. SwiftUI then hands `host(_:)` the destination's web
        /// view. If it doesn't (nothing left open removes this view instead), put things back.
        private func swipeDidCommit(_ swipe: BackSwipe) {
            swipe.close()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.swipe === swipe else { return }
                if let webView = self.webView { BackSwipe.reset(webView) }
                swipe.tearDown()
                self.swipe = nil
            }
        }

        private func cancelSwipe() {
            guard let swipe else { return }
            if let webView { BackSwipe.reset(webView) }
            swipe.tearDown()
            self.swipe = nil
            // Ends a drag still under the finger; the recognizer is usable again straight away.
            edgePan.isEnabled = false
            edgePan.isEnabled = true
        }
    }
}

/// One back-swipe-to-close, after Arc: the page lifts into a slightly smaller rounded card that
/// follows the finger, over the destination tab's snapshot. With Reduce Motion the page stays put
/// and fades instead.
@MainActor
private final class BackSwipe {
    let close: () -> Void
    private(set) var isCommitted = false
    private let webView: WKWebView
    private let underlay: UIImageView
    private let shadow = UIView()
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    /// Distance over which the page shrinks to its card size; it then only slides.
    private static let liftDistance: CGFloat = 80
    private static let cardScale: CGFloat = 0.94
    private static let cardCornerRadius: CGFloat = 36

    init(webView: WKWebView, in container: UIView, snapshot: UIImage?, close: @escaping () -> Void) {
        self.webView = webView
        self.close = close
        underlay = UIImageView(image: snapshot)
        underlay.frame = webView.frame
        underlay.contentMode = .scaleAspectFill
        underlay.clipsToBounds = true
        underlay.backgroundColor = .systemBackground
        container.insertSubview(underlay, belowSubview: webView)
        guard !reduceMotion else { return }
        shadow.frame = webView.frame
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.3
        shadow.layer.shadowRadius = 16
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds,
                                               cornerRadius: Self.cardCornerRadius).cgPath
        shadow.alpha = 0
        container.insertSubview(shadow, belowSubview: webView)
        webView.layer.cornerCurve = .continuous
        webView.layer.masksToBounds = true
    }

    func track(_ translation: CGFloat) {
        let distance = max(0, translation)
        if reduceMotion {
            webView.alpha = 1 - min(1, distance / max(webView.bounds.width, 1))
            return
        }
        let lift = min(1, distance / Self.liftDistance)
        apply(offset: distance, lift: lift)
    }

    func commit(then completion: @escaping () -> Void) {
        isCommitted = true
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            if self.reduceMotion {
                self.webView.alpha = 0
            } else {
                self.apply(offset: self.webView.bounds.width + Self.cardCornerRadius, lift: 1)
            }
        } completion: { _ in completion() }
    }

    func cancel(then completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            if self.reduceMotion {
                self.webView.alpha = 1
            } else {
                self.apply(offset: 0, lift: 0)
            }
        } completion: { _ in
            Self.reset(self.webView)
            self.tearDown()
            completion()
        }
    }

    /// Fades the snapshot off the destination's web view, which `host(_:)` has just put on top, once
    /// that has a page up: a web view rebuilt after eviction starts blank and loads (capped, in case
    /// it never settles).
    func fadeOut(over destination: WKWebView, in container: UIView, then completion: @escaping () -> Void) {
        shadow.removeFromSuperview()
        container.bringSubviewToFront(underlay)
        Task {
            var waited = 0
            while destination.url == nil || destination.isLoading, waited < 30 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            UIView.animate(withDuration: 0.15, delay: 0.05) {
                self.underlay.alpha = 0
            } completion: { _ in
                self.underlay.removeFromSuperview()
                completion()
            }
        }
    }

    func tearDown() {
        underlay.removeFromSuperview()
        shadow.removeFromSuperview()
    }

    /// Puts a web view back as `WebViewContainer` hosts it.
    static func reset(_ webView: WKWebView) {
        webView.transform = .identity
        webView.alpha = 1
        webView.layer.cornerRadius = 0
        webView.layer.cornerCurve = .circular
        webView.layer.masksToBounds = false
    }

    private func apply(offset: CGFloat, lift: CGFloat) {
        let scale = 1 - (1 - Self.cardScale) * lift
        let transform = CGAffineTransform(translationX: offset, y: 0).scaledBy(x: scale, y: scale)
        webView.transform = transform
        webView.layer.cornerRadius = Self.cardCornerRadius * lift
        shadow.transform = transform
        shadow.alpha = lift
    }
}
