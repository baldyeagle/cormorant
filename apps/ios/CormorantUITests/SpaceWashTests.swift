import XCTest

/// The wash covers a new tab until its page has drawn: WebKit can paint a white canvas for a moment
/// before a page's own dark styles apply, which flashed white in dark mode. Watched through
/// `UITesting.wash`; the page is held back by `FixtureServer` rather than raced.
@MainActor
final class SpaceWashTests: UITestCase {
    /// Text to paint, and an image the server holds back so the page never finishes loading: the
    /// wash can only go because the page said it drew, not because loading stopped.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        <title>Wash page</title>
        <h1>Wash page</h1>
        <p>Body text for Wash page.</p>
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
                      "the page didn't load")
        XCTAssertTrue(waitUntil(Ceiling.ui) { wash.value as? String == "down" }, "the wash stayed over the drawn page")
        XCTAssertTrue(waitUntil(Ceiling.load) { server.requestCount(for: "/image") == 1 }, "the image wasn't asked for")
        server.release("/image")
        withExtendedLifetime(server) {}
    }
}
