import CormorantBrowser
import CormorantCore
import SwiftUI
import UIKit
import WebKit

/// A tab's iPhone side: pull to refresh, the bar collapsing as the page scrolls, find on page, the
/// long-press link menu (`LinkContextMenu.swift`) and the page's dialogs.
@Observable
final class IOSTabChrome: NSObject, TabChrome, WKUIDelegate {
    /// Set while the user scrolls down a page; the bottom bar shrinks to a strip.
    var isBarCollapsed = false
    /// Work the actions sheet hands off to run once it has finished dismissing. See `runPendingAction()`.
    @ObservationIgnored var pendingAction: PendingAction?
    /// The long-press menu's page preview, while one is up. See `LinkContextMenu.swift`.
    @ObservationIgnored weak var linkPreview: LinkPreviewController?
    /// The color behind the status bar for whichever tab is on screen, for an animation that hands
    /// over to it (the link preview's card growing into its new tab).
    @ObservationIgnored var activeStripColor: ((UIUserInterfaceStyle) -> UIColor?)?
    @ObservationIgnored let platform: IOSBrowserPlatform

    @ObservationIgnored private weak var session: TabSession?
    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private let pullToRefresh: PullToRefresh
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var traitRegistration: (any UITraitChangeRegistration)?
    @ObservationIgnored private var lastScrollY: CGFloat = 0
    @ObservationIgnored private var lastInsetTop: CGFloat = 0
    @ObservationIgnored private var scrollTravel: CGFloat = 0

    private static let collapseDistance: CGFloat = 24

    init(session: TabSession, platform: IOSBrowserPlatform, activeStripColor: @escaping (UIUserInterfaceStyle) -> UIColor?) {
        self.session = session
        self.platform = platform
        self.activeStripColor = activeStripColor
        webView = session.webView
        pullToRefresh = PullToRefresh(webView: webView)
        super.init()
        webView.isFindInteractionEnabled = true
        pullToRefresh.onRefresh = { [weak session] in session?.reload() }
        // A tab adopting a link preview's page has one before anything here observes it.
        pullToRefresh.pageDidChange(webView.url)
        // WKWebView and UIScrollView post these KVO changes on the main thread.
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    self?.setBarCollapsed(false)
                    self?.pullToRefresh.pageDidChange(web.url)
                }
            },
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.scrollViewDidScroll(scrollView) }
            },
        ]
        traitRegistration = webView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak session] (_: WKWebView, _: UITraitCollection) in
            session?.pageBackgroundDidChange()
        }
    }

    /// Something the actions sheet asked for that can only happen once the sheet is gone.
    enum PendingAction {
        /// The find navigator needs first responder, which the dismissing sheet still holds.
        case findOnPage
    }

    /// Call from the actions sheet's `onDismiss`. Runs and clears `pendingAction`.
    func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .findOnPage:
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    func setBarCollapsed(_ collapsed: Bool) {
        guard isBarCollapsed != collapsed else { return }
        withAnimation(.snappy(duration: 0.25)) { isBarCollapsed = collapsed }
    }

    /// Collapses the bar after a short scroll down, expands it after a short scroll up or at the top.
    private func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let insetTop = scrollView.adjustedContentInset.top
        let y = scrollView.contentOffset.y + insetTop
        // The pull-to-refresh spinner adds and removes top inset, which shifts `y` with no scrolling;
        // that shift mustn't count as travel (a spinner ending mid-scroll would expand the bar).
        let delta = insetTop == lastInsetTop ? y - lastScrollY : 0
        lastScrollY = y
        lastInsetTop = insetTop
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if y <= 0 {
            setBarCollapsed(false)
            return
        }
        // At the end of the scroll range, offset changes come from bounce and inset clamping, not
        // from the user's intent; leave the bar as it is.
        let maxY = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        if y >= maxY - 1 {
            scrollTravel = 0
            return
        }
        if (delta > 0) != (scrollTravel > 0) { scrollTravel = 0 }
        scrollTravel += delta
        if scrollTravel > Self.collapseDistance {
            setBarCollapsed(true)
        } else if scrollTravel < -Self.collapseDistance {
            setBarCollapsed(false)
        }
    }

    func newTab(for click: WKNavigationAction) -> NewTabRequest? { nil }

    func tabDidBecomeActive() {
        // Asked for while another tab's sheet was open; it must not fire on a later dismissal.
        pendingAction = nil
    }

    func tabDidResignActive() {
        pullToRefresh.cancel()
    }

    func sessionDidDetach() {
        activeStripColor = nil
    }

    func pageBackground() -> PageBackground? {
        let style = webView.traitCollection.userInterfaceStyle
        guard let appearance = Appearance(style),
              let color = RGBColor(webView.underPageBackgroundColor, in: UITraitCollection(userInterfaceStyle: style))
        else { return nil }
        return PageBackground(color: color, appearance: appearance)
    }

    /// Presents from the web view's window scene; false when it's off screen, its scene is in the
    /// background, or an alert is up already.
    func present(_ dialog: PageDialog) -> Bool {
        guard let presenter = webView.alertPresenter else { return false }
        let alert: UIAlertController
        switch dialog {
        case .alert(let title, let message, let done):
            alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
        case .confirm(let title, let message, let done):
            alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(true) })
        case .prompt(let title, let message, let defaultText, let done):
            alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                done(alert?.textFields?.first?.text ?? "")
            })
        case .openInOtherApp(let url, let appName):
            alert = UIAlertController(title: "Open in \(appName)?", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        presenter.present(alert, animated: true)
        return true
    }

    // MARK: Link menu
    // Implementing these keeps WebKit from falling back to the system's link menu, whose Open Link
    // and preview tap send the URL to the default browser instead of this tab.

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL else { return nil }
        return session?.linkMenuConfiguration(for: url)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating
    ) {
        session?.commitLinkPreview(elementInfo.linkURL, animator: animator)
    }

    func webView(_ webView: WKWebView, contextMenuDidEndForElement elementInfo: WKContextMenuElementInfo) {
        session?.linkMenuDidEnd(for: elementInfo.linkURL)
    }
}

extension TabSession {
    /// Every tab in the iPhone app has one (`IOSBrowserPlatform.makeChrome`).
    var ui: IOSTabChrome { chrome as! IOSTabChrome }
}
