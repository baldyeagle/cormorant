import CormorantCore
import Foundation
import Testing
import UIKit
import WebKit
@testable import Cormorant

extension AppTests {
    /// The long-press link menu's actions, run as the menu runs them: its preview is the one UIKit asks
    /// the tab for as the menu comes up (`makeLinkPreview(for:)`), an item's action runs once it's
    /// chosen, and then the menu ends (`linkMenuDidEnd(for:)`), stopping a preview no tab took. Which
    /// items a link gets is read from the menu the tab builds. The long-press, the menu and preview
    /// coming up, and a tapped preview growing into its tab stay in CormorantUITests'
    /// LinkContextMenuTests.
    @Suite("Link menu")
    @MainActor
    struct LinkMenuTests {
        /// Every path serves this page; its heading names the path it was loaded at.
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
            <h1 id="path">Path</h1>
            <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
            <a href="/next">Next page</a>
            <a href="/slow">Slow page</a>
            <a href="/third">Third page</a>
            <a href="/popup" target="_blank">Blank target</a>
            """

        /// Picked before the preview has a page (its request for `/slow` is held back), so the new tab
        /// loads the link itself rather than adopting the preview.
        @Test func openInNewTabLoadsLinkWhenPreviewHasNoPage() async throws {
            let server = try FixtureServer(html: Self.page, holds: ["/slow"])
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let slow = server.url.appending(path: "slow")

            let preview = opener.makeLinkPreview(for: slow)
            try await browser.until("the preview to ask for /slow; \(server.requestLog)") { server.requestCount(for: "/slow") == 1 }
            try choose("Open in New Tab", for: slow, in: opener)

            #expect(browser.store.tabs.count == 2, "no new tab")
            let tab = try #require(browser.store.activeSession)
            #expect(tab !== opener, "didn't switch to the new tab")
            #expect(tab.webView !== preview.webView, "the new tab took a preview with no page")
            // The tab's own request, held like the preview's until the test lets both through.
            try await browser.until("the new tab to ask for /slow itself; \(server.requestLog)") { server.requestCount(for: "/slow") == 2 }
            server.release("/slow")
            try await browser.waitForPage("/slow")
            #expect(browser.store.activeSession === tab)
            // The preview's request and the tab's own: the tab didn't adopt the preview.
            #expect(server.requestCount(for: "/slow") == 2, "\(server.requestLog)")
            withExtendedLifetime(preview) {}
        }

        /// Picked before the preview has a page, so the tab loads it itself, in the background, behind
        /// the page on screen, and has its snapshot for the switcher without ever being shown.
        @Test func openInBackgroundTabKeepsCurrentPageAndLoadsIt() async throws {
            let server = try FixtureServer(html: Self.page, holds: ["/slow"])
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let window = try #require(opener.webView.window)
            let slow = server.url.appending(path: "slow")

            let preview = opener.makeLinkPreview(for: slow)
            try await browser.until("the preview to ask for /slow; \(server.requestLog)") { server.requestCount(for: "/slow") == 1 }
            try choose("Open in Background Tab", for: slow, in: opener)

            #expect(browser.store.tabs.count == 2, "no background tab")
            #expect(browser.store.activeSession === opener, "left the current page")
            let tab = try #require(browser.store.tabs.first { $0.id != opener.tabID })
            // Loading on the stage while its request is held: a web view of its own, behind everything
            // else in the window, that nothing can touch.
            try await browser.until("the background tab to ask for /slow itself; \(server.requestLog)") {
                server.requestCount(for: "/slow") == 2
            }
            let staged = try #require(Self.stagedWebView(in: window, besides: opener.webView), "nothing on the stage")
            #expect(staged !== preview.webView, "the background tab took a preview with no page")
            let stage = try #require(staged.superview)
            #expect(window.subviews.first === stage, "the stage isn't behind the page")
            #expect(!stage.isUserInteractionEnabled, "the stage can be touched")

            server.release("/slow")
            try await browser.until("the background tab's snapshot") { browser.store.snapshots[tab.id] != nil }
            #expect(staged.url?.path() == "/slow")
            #expect(browser.store.snapshots[opener.tabID] != nil, "the current page has no snapshot")
            // Taken off the stage once snapshotted, so it stops painting.
            try await browser.until("the background tab to leave the stage") { staged.superview == nil }
            #expect(browser.store.activeSession === opener, "the background tab was shown")
            #expect(opener.webView.url?.path() == "/")
            // The preview's request and the tab's own: the tab loaded the link itself.
            #expect(server.requestCount(for: "/slow") == 2, "\(server.requestLog)")
            withExtendedLifetime(preview) {}
        }

        /// The preview has the page: the background tab takes it over, with no second request.
        @Test func openInBackgroundTabAdoptsLoadedPreview() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let next = server.url.appending(path: "next")

            let preview = try await loadedPreview(of: next, in: opener, browser: browser)
            try choose("Open in Background Tab", for: next, in: opener)

            #expect(browser.store.tabs.count == 2, "no background tab")
            #expect(browser.store.activeSession === opener, "left the current page")
            let tab = try #require(browser.store.tabs.first { $0.id != opener.tabID })
            #expect(preview.webView.superview != nil && preview.webView.window === opener.webView.window,
                    "the background tab isn't loading the preview's page on the stage")
            try await browser.until("the background tab's snapshot") { browser.store.snapshots[tab.id] != nil }
            #expect(browser.store.snapshots[opener.tabID] != nil, "the current page has no snapshot")
            #expect(browser.store.activeSession === opener, "the background tab was shown")
            #expect(server.requestCount(for: "/next") == 1, "the page was loaded again; \(server.requestLog)")
        }

        /// The preview has the page: the new tab takes it over, with no second request.
        @Test func openInNewTabAdoptsLoadedPreview() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let next = server.url.appending(path: "next")

            let preview = try await loadedPreview(of: next, in: opener, browser: browser)
            try choose("Open in New Tab", for: next, in: opener)

            #expect(browser.store.tabs.count == 2, "no new tab")
            #expect(browser.store.activeSession !== opener, "didn't switch to the new tab")
            #expect(browser.store.activeSession?.webView === preview.webView, "the new tab didn't take the preview's page")
            try await browser.waitForPage("/next")
            #expect(server.requestCount(for: "/next") == 1, "the page was loaded again; \(server.requestLog)")
        }

        @Test func copyLinkCopiesURL() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let next = server.url.appending(path: "next")

            try choose("Copy Link", for: next, in: opener)
            #expect(UIPasteboard.general.changeCount == OwnPasteboardWrite.changeCount, "nothing was copied")
            #expect(UIPasteboard.general.url == next)
        }

        /// `target=_blank` doesn't matter to the menu: Open Link still means this tab.
        @Test func blankTargetOpenLinkStaysInCurrentTab() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let popup = server.url.appending(path: "popup")

            try choose("Open Link", for: popup, in: opener)
            try await browser.waitForPage("/popup")
            #expect(browser.store.activeSession === opener, "Open Link left this tab")
            #expect(browser.store.tabs.count == 1, "Open Link changed the tab count")
        }

        /// Another app's link can't load in a tab; Open Link asks first, as a tap does.
        @Test func mailLinkOffersNoTabsAndAsksBeforeOpening() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let mail = try #require(URL(string: "mailto:someone@example.com"))

            let items = try menuItems(for: mail, in: opener)
            #expect(items.contains("Copy Link"))
            #expect(items.contains("Open Link"))
            #expect(!items.contains("Open in New Tab"))
            #expect(!items.contains("Open in Background Tab"))

            // Where the tab puts up its alerts, read before one is up.
            let host = try #require(opener.webView.alertPresenter)
            try choose("Open Link", for: mail, in: opener)
            try await browser.until("a confirmation before opening Mail") {
                (host.presentedViewController as? UIAlertController).map { !$0.isBeingPresented } ?? false
            }
            let alert = try #require(host.presentedViewController as? UIAlertController)
            #expect(alert.title == "Open in Mail?")
            // Cancel opens nothing; only Open hands the link to Mail.
            #expect(alert.actions.map(\.title) == ["Cancel", "Open"])
            #expect(alert.actions.first?.style == .cancel)
            await host.dismiss(animated: false)
            #expect(browser.store.tabs.count == 1)
            #expect(opener.webView.url?.path() == "/", "the tab left its page")
        }

        /// A tap can't open a data: URL top-level, so the menu doesn't either.
        @Test func dataLinkOffersCopyOnly() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url)
            let opener = try #require(browser.store.activeSession)
            let data = try #require(URL(string: "data:text/html,%3Ch1%3EData%20page%3C/h1%3E"))

            let items = try menuItems(for: data, in: opener)
            #expect(items.contains("Share Link"))
            #expect(items.contains("Copy Link"))
            #expect(!items.contains("Open Link"))
            #expect(!items.contains("Open in New Tab"))
            #expect(!items.contains("Open in Background Tab"))
        }

        // MARK: Helpers

        /// The titles of the menu `session` gives `url`'s long-press, submenus' included.
        private func menuItems(for url: URL, in session: TabSession,
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
            try #require(session.linkMenuConfiguration(for: url) != nil, "no menu", sourceLocation: sourceLocation)
            func titles(_ element: UIMenuElement) -> [String] {
                guard let menu = element as? UIMenu else { return [element.title] }
                return (menu.title.isEmpty ? [] : [menu.title]) + menu.children.flatMap(titles)
            }
            return session.linkMenu(for: url, kind: TabSession.linkKind(for: url)).children.flatMap(titles)
        }

        /// Picks `title` from `url`'s menu in `session`: its action runs, then the menu ends, as WebKit
        /// reports once the menu has gone.
        private func choose(_ title: String, for url: URL, in session: TabSession,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(try menuItems(for: url, in: session, sourceLocation: sourceLocation).contains(title),
                    "no \(title) item", sourceLocation: sourceLocation)
            let actions = session.linkMenuActions(for: url, kind: TabSession.linkKind(for: url))
            let action = try #require((actions.open + actions.pass).first { $0.title == title }, "no \(title) action",
                                      sourceLocation: sourceLocation)
            action.perform()
            session.linkMenuDidEnd(for: url)
        }

        /// The menu's preview of `url`, once it has the page.
        private func loadedPreview(of url: URL, in session: TabSession, browser: TestBrowser,
                                   sourceLocation: SourceLocation = #_sourceLocation) async throws -> LinkPreviewController {
            let preview = session.makeLinkPreview(for: url)
            try await browser.until("the preview to load \(url.path())", sourceLocation: sourceLocation) {
                preview.webView.url?.path() == url.path() && !preview.webView.isLoading
            }
            return preview
        }

        /// The web view loading on the background stage: in `window` but not under its root view.
        private static func stagedWebView(in window: UIWindow, besides shown: WKWebView) -> WKWebView? {
            let root = window.rootViewController?.view
            return window.subviews.lazy.filter { $0 !== root }
                .flatMap(\.subviews).compactMap { $0 as? WKWebView }.first { $0 !== shown }
        }
    }
}
