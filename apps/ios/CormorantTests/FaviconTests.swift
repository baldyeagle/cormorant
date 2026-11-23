import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
import UIKit
@testable import Cormorant

extension AppTests {
    /// Site icons for tiles, cards and the search panel's rows (`FaviconStore`).
    @Suite("Favicons")
    @MainActor
    struct FaviconTests {
        /// Behind a sign-in (Cloudflare Access, say) a fetch without the page's cookies only gets the
        /// sign-in page. Signed out, the icon can't come at all, and that doesn't hold the next try back;
        /// signed in, it comes through the page itself.
        @Test func aSiteBehindASignInGetsItsIconOnceSignedIn() async throws {
            let icon = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
                UIColor.systemPurple.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            // Without the cookie, everything but `/login` goes to `/login`.
            let server = try FixtureServer(html: """
                <!doctype html>
                <link rel="icon" href="/favicon.ico">
                <script>document.title = 'Page ' + location.pathname</script>
                """, files: ["/favicon.ico": .init(contentType: "image/png", body: icon)], signIn: "session=ok")
            let browser = try await TestBrowser()
            defer { browser.close() }
            let app = server.url.appending(path: "app")

            // Signed out: both tries, without the cookie and through the page, get the sign-in page.
            browser.store.submit(app.absoluteString)
            try await browser.waitForPage("/login")
            try await browser.until("both tries for the icon (\(server.requestLog))") {
                server.requestCount(for: "/favicon.ico") >= 2 && !browser.store.favicons.isFetching(app)
            }
            #expect(browser.store.favicons.icon(for: app) == nil)

            // Signed in, the next load gets it.
            _ = try await browser.evaluate("document.cookie = 'session=ok; path=/', 1")
            try await browser.open(app)
            try await browser.until("the icon to arrive (\(server.requestLog))") {
                browser.store.favicons.icon(for: app) != nil
            }
            withExtendedLifetime(server) {}
        }
    }
}
