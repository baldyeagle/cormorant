import CormorantTestSupport
import XCTest

/// Incognito end to end: the search panel's Incognito button turns the panel Incognito, the tab it
/// opens says "Incognito" under the status bar, and closing its card in the switcher ends Incognito
/// with a toast. What Incognito keeps (nothing), its website data and where its links open are
/// CormorantTests' IncognitoTests.
@MainActor
final class IncognitoTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        """

    func testIncognitoTabOpensAndEnds() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        let toggle = app.buttons["IncognitoToggle"]
        XCTAssertTrue(toggle.appears(within: Ceiling.ui), "no Incognito button on a new tab")
        XCTAssertEqual(toggle.value as? String, "Off")
        toggle.tapWhenSettled()
        XCTAssertTrue(waitUntil(Ceiling.ui) { toggle.value as? String == "On" }, "the Incognito button didn't turn on")
        XCTAssertTrue(app.descendants(matching: .any)["IncognitoNote"].appears(within: Ceiling.ui),
                      "the panel doesn't say it's Incognito")

        field.typeText(server.url.appending(path: "private").absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Path /private"].firstMatch.appears(within: Ceiling.load),
                      "the Incognito tab didn't load")
        XCTAssertTrue(app.descendants(matching: .any)["IncognitoLabel"].appears(within: Ceiling.ui),
                      "no Incognito label under the status bar")

        app.buttons["Tabs, 1 open"].tapWhenSettled()
        XCTAssertTrue(app.buttons["SpaceTitleMenu"].appears(within: Ceiling.ui), "the switcher isn't on Incognito")
        XCTAssertEqual(app.buttons["SpaceTitleMenu"].label, "Space, Incognito")
        XCTAssertFalse(app.buttons["Archive"].exists, "Incognito's switcher offers the archive")
        app.buttons["Close"].firstMatch.tapWhenSettled()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Incognito closed'")).firstMatch
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast as Incognito ended")
        XCTAssertTrue(app.buttons["Archive"].appears(within: Ceiling.ui), "the switcher didn't go back to Home")
        withExtendedLifetime(server) {}
    }
}
