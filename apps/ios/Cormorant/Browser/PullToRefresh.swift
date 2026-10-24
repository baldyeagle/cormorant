import UIKit
import WebKit

/// Pull down from the top of a page to reload it, like Safari. A system `UIRefreshControl` on the
/// web view's scroll view, so the pull distance, spinner and haptic are the system's own.
///
/// The control commits as soon as the pull crosses its threshold, but the reload waits for the
/// finger to lift: reloading under a held drag lets WebKit reset the scroll position mid-gesture.
/// Pushing the page back up over the spinner before lifting, or an interrupted touch, calls it off.
/// The spinner stays until the reload stops loading (finished, failed, stopped or replaced by
/// another navigation), and goes at once when the tab leaves the screen.
///
/// Only the main scroll view carries the control, so a page's own scrollers (`overflow: auto`) keep
/// their gestures, and a page that turns off overscroll (`overscroll-behavior: none`, a
/// `touchmove` handler that prevents scrolling) can't be pulled either.
@MainActor
final class PullToRefresh: NSObject {
    /// Called on release once a pull has committed.
    var onRefresh: (() -> Void)?

    private let control = UIRefreshControl()
    private weak var webView: WKWebView?
    private var state = State.idle
    /// The scroll view's top inset when the drag began, before the spinner adds to it.
    private var restingInsetTop: CGFloat = 0
    private var loadingObservation: NSKeyValueObservation?
    private var deadline: Task<Void, Never>?

    private enum State {
        case idle
        /// Pulled past the threshold with the finger still down.
        case armed
        case loading
    }

    /// Past this the bar's progress line carries on alone, so a hung subresource can't hold the
    /// spinner (and the page pushed down under it) indefinitely.
    private static let loadTimeout: Duration = .seconds(15)

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        control.addTarget(self, action: #selector(didCommitPull), for: .valueChanged)
        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(didPan(_:)))
        // WKWebView posts this KVO change on the main thread.
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.loadingDidChange(web.isLoading) }
        }
    }

    /// The web view can outlive this (the container holds it until another tab is shown), and UIKit
    /// doesn't retain gesture or control targets.
    isolated deinit {
        webView?.scrollView.panGestureRecognizer.removeTarget(self, action: nil)
        control.removeTarget(self, action: nil, for: .allEvents)
    }

    /// Call when the page's URL changes. Only real pages get the control; a blank tab has nothing to
    /// reload, so there is nothing to pull.
    func pageDidChange(_ url: URL?) {
        guard let scrollView = webView?.scrollView else { return }
        let reloadable = url.map { $0.scheme?.lowercased() != "about" } ?? false
        if reloadable, scrollView.refreshControl !== control {
            scrollView.refreshControl = control
        } else if !reloadable, scrollView.refreshControl === control {
            end()
            scrollView.refreshControl = nil
        }
    }

    /// Call when the tab leaves the screen. Drops a pending pull and hides the spinner; a reload
    /// already under way carries on.
    func cancel() { end() }

    // MARK: Private

    @objc private func didPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if state == .idle, let scrollView = webView?.scrollView {
                restingInsetTop = scrollView.adjustedContentInset.top
            }
            matchSpinnerToPage()
        case .ended:
            guard state == .armed, let scrollView = webView?.scrollView else { return }
            // Measured against the inset from before the spinner appeared, so it doesn't matter
            // when UIKit adds the spinner's height: still pulled down reloads, pushed back doesn't.
            let pulled = -(scrollView.contentOffset.y + restingInsetTop)
            if pulled > 0 { refresh() } else { end() }
        case .cancelled, .failed:
            if state == .armed { end() }
        default:
            break
        }
    }

    @objc private func didCommitPull() {
        guard control.isRefreshing, state == .idle else { return }
        let pan = webView?.scrollView.panGestureRecognizer.state
        if pan == .began || pan == .changed {
            state = .armed
        } else {
            refresh()
        }
    }

    private func refresh() {
        guard let onRefresh, let webView else {
            end()
            return
        }
        onRefresh()
        // `isLoading` turns on during `reload()`; still off, WebKit didn't start one. Set after
        // asking, so an earlier load cancelled during the call isn't taken for the end of this one.
        guard webView.isLoading else {
            end()
            return
        }
        state = .loading
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            if !Task.isCancelled { self?.end() }
        }
    }

    private func loadingDidChange(_ isLoading: Bool) {
        if state == .loading, !isLoading { end() }
    }

    private func end() {
        state = .idle
        deadline?.cancel()
        deadline = nil
        if control.isRefreshing { control.endRefreshing() }
    }

    /// The spinner sits on whatever WebKit draws behind the page, which follows the page's own
    /// background rather than the system appearance (a dark page in light mode, and the reverse).
    /// Tint it for that background: the system's gray spinner fades into dark pages. (The control
    /// ignores `overrideUserInterfaceStyle`, hence a resolved tint.)
    private func matchSpinnerToPage() {
        guard let webView else { return }
        let background = webView.underPageBackgroundColor.resolvedColor(with: webView.traitCollection)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.5 else {
            control.tintColor = nil
            return
        }
        // WCAG relative luminance; below about 0.18, light text has more contrast than dark.
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let style: UIUserInterfaceStyle = luminance < 0.18 ? .dark : .light
        // The spinner's spokes fade this color further, so it starts stronger than secondary text.
        control.tintColor = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .withAlphaComponent(0.7)
    }
}
