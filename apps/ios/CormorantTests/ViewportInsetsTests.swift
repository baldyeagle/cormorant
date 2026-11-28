import CormorantTestSupport
import Foundation
import Testing
import UIKit
import WebKit
@testable import Cormorant
@testable import CormorantBrowser

extension AppTests {
    /// What a page sees of the area the browser's chrome covers (`WebViewContainer.cover(_:with:)`): its
    /// viewport stops at the bottom bar, by `innerHeight` and the small, large and dynamic viewport
    /// units. An app-like page sized to `100svh` (a chat with its composer at the bottom) had that
    /// composer under the bar, where it couldn't be tapped: `obscuredContentInsets` alone moves fixed
    /// elements, `innerHeight` and `dvh`, but not `svh` or `lvh`. Plain `vh` stays the whole web view,
    /// as in Safari: no public API reaches it.
    @Suite("Viewport insets")
    @MainActor
    struct ViewportInsetsTests {
        /// Puts the height of each viewport unit, and `innerHeight`, in its title whenever one changes.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body { margin: 0 } .unit { position: absolute; top: 0; width: 1px }</style>
            <title>Viewport</title>
            <div class="unit" id="svh" style="height: 100svh"></div>
            <div class="unit" id="lvh" style="height: 100lvh"></div>
            <div class="unit" id="dvh" style="height: 100dvh"></div>
            <script>
            const units = ['svh', 'lvh', 'dvh'].map(id => document.getElementById(id))
            const report = () => {
                document.title = units.map(unit => unit.id + '=' + Math.round(unit.getBoundingClientRect().height))
                    .concat('inner=' + innerHeight).join(' ')
            }
            const observer = new ResizeObserver(report)
            units.forEach(unit => observer.observe(unit))
            addEventListener('resize', report)
            report()
            </script>
            """

        @Test func everyViewportUnitStopsAtTheBar() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let webView = try #require(browser.store.activeSession?.webView)
            // A bottom bar and the home indicator, and a status bar the page runs under.
            let covered = UIEdgeInsets(top: 47, left: 0, bottom: 94, right: 0)
            WebViewContainer.cover(webView, with: covered)
            let uncovered = Int((webView.bounds.height - covered.top - covered.bottom).rounded())
            let expected = "svh=\(uncovered) lvh=\(uncovered) dvh=\(uncovered) inner=\(uncovered)"
            try await browser.until("the page's viewport to be \(expected) (it's \(webView.title ?? "untitled"))") {
                webView.title == expected
            }

            // A page loaded off screen (a background tab, a link preview) is covered as the tab on screen is.
            let staged = WKWebView(frame: .zero)
            PageLayout(of: webView).apply(to: staged)
            #expect(staged.obscuredContentInsets == covered)
            #expect(staged.minimumViewportInset == covered)
            #expect(staged.maximumViewportInset == covered)
        }

        /// The browser screen's container covers its web view with the bottom bar (and nothing at the
        /// top or sides outside a window, which has no safe area), once the bar's height is known.
        @Test func containerCoversTheBar() {
            let webView = WKWebView(frame: .zero)
            let container = WebViewContainer.ContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            container.host(webView)
            container.barHeight = 60
            let covered = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
            #expect(webView.obscuredContentInsets == covered)
            #expect(webView.minimumViewportInset == covered)
            #expect(webView.maximumViewportInset == covered)
        }
    }
}
