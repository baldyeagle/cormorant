import CormorantTestSupport
import XCTest

/// The wash covers a new tab until its page has drawn: WebKit can paint a white canvas for a moment
/// before a page's own dark styles apply, which flashed white in dark mode. Watched through
/// `UITesting.wash`; the page is held back by `FixtureServer` rather than raced.
@MainActor
final class SpaceWashTests: UITestCase {
    /// Text to paint, and an image the server holds back so the page never finishes loading: the
    /// wash can't go because loading stopped, only because the page said it drew (or the fallback
    /// three seconds after the page arrived).
    ///
    /// The text has to be over 200 characters, not counting whitespace. After a navigation WebKit
    /// keeps the layer tree frozen, painting nothing, until the page is "visually non-empty"
    /// (`LocalFrameView::checkAndDispatchDidReachVisuallyNonEmptyState`): more than 200 characters
    /// or 32×32 pixels of content, or less once parsing has finished (with no stylesheet or font
    /// still loading), or the load having completed. Until then it checks again only when the render
    /// tree changes. A short page whose render tree was built after the whole page was parsed but
    /// before the parser was told the file had ended never changes again, the held image keeps the
    /// load from completing, and the page never draws: the likely cause of a failure seen about one
    /// run in twenty on a loaded machine. The text is in several elements because WebKit counts a
    /// text node's characters when its renderer is made, not text added to it later.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        <title>Wash page</title>
        <h1>Wash page</h1>
        <p>Body text for Wash page.</p>
        <p>Enough text that WebKit counts the page as having content as soon as it's rendered,</p>
        <p>without waiting for the parser to finish or for the load to complete, so the page draws</p>
        <p>when its text arrives, however the parser's chunks and WebKit's first style pass line up</p>
        <p>on a busy machine. Each line is short, so no single text node has to carry the count.</p>
        <img src="/image" alt="">
        """

    func testWashCoversANewTabUntilItsPageDraws() throws {
        let server = try FixtureServer(html: Self.page, holds: ["/page", "/image"])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingAppearance", "dark"]
        app.launch()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        let wash = app.descendants(matching: .any)["UITesting.wash"].firstMatch
        XCTAssertEqual(wash.value as? String, "up", "no wash behind the blank tab")

        field.typeText(server.url.appending(path: "page").absoluteString + "\n")
        XCTAssertTrue(waitUntil(Ceiling.load) { server.requestCount(for: "/page") == 1 }, "the page wasn't asked for")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        XCTAssertEqual(wash.value as? String, "up", "the wash went before the page arrived")

        server.release("/page")
        XCTAssertTrue(app.webViews.staticTexts["Body text for Wash page."].appears(within: Ceiling.load),
                      "the page didn't load; \(server.requestLog)")
        XCTAssertTrue(waitUntil(Ceiling.ui) { wash.value as? String == "down" }, "the wash stayed over the drawn page")
        XCTAssertTrue(waitUntil(Ceiling.load) { server.requestCount(for: "/image") == 1 }, "the image wasn't asked for")
        server.release("/image")
        withExtendedLifetime(server) {}
    }
}
