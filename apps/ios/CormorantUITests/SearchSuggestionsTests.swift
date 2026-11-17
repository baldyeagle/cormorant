import XCTest

/// Typing in the search panel: the field completes to a visited site, and backspace takes the
/// completion away. An open tab's row switches to it, end to end, and Search Tabs' token goes back to
/// searching everything with the field still focused. Which rows the panel lists, and what choosing
/// one does, are CormorantTests' SearchPanelTests.
@MainActor
final class SearchSuggestionsTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname;
          document.title = 'Page ' + location.pathname.slice(1);
        </script>
        """

    func testFieldCompletesToAVisitedSiteAndBackspaceTakesItAway() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)

        let field = newTabField(in: app)
        let site = "127.0.0.1:\(server.url.port!)"
        field.typeText("127")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value as? String == site },
                      "no completion: \(field.value ?? "nil")")
        // The completion is selected: one backspace removes all of it, and it doesn't come back.
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value as? String == "127" }, "backspace left \(field.value ?? "nil")")
        XCTAssertFalse(waitUntil(1) { field.value as? String != "127" }, "the completion came back")
        // Typing on completes again.
        field.typeText(".")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value as? String == site },
                      "no completion after typing on: \(field.value ?? "nil")")
        withExtendedLifetime(server) {}
    }

    /// A caret placed after the completion accepts it: backspace then deletes one letter, and the
    /// completion doesn't come back over it.
    func testBackspaceAfterAcceptingACompletionDeletesALetter() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)

        let field = newTabField(in: app)
        let site = "127.0.0.1:\(server.url.port!)"
        field.typeText("127")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value as? String == site }, "no completion: \(field.value ?? "nil")")
        // Past the text's end, short of the clear button: the caret goes to the end.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        let shortened = String(site.dropLast())
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value as? String == shortened }, "backspace left \(field.value ?? "nil")")
        XCTAssertFalse(waitUntil(1) { field.value as? String != shortened }, "the completion came back")
        withExtendedLifetime(server) {}
    }

    func testOpenTabRowSwitchesInsteadOfLoadingAgain() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)
        newTabField(in: app).typeText(server.url.appending(path: "beta").absoluteString + "\n")
        XCTAssertTrue(heading("/beta", in: app).appears(within: Ceiling.load), "/beta didn't load")
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui))

        newTabField(in: app).typeText("alpha")
        let row = app.buttons.matching(NSPredicate(format: "label == 'Page alpha' AND value ENDSWITH 'open tab'")).firstMatch
        XCTAssertTrue(row.appears(within: Ceiling.ui), "no open-tab row for /alpha")
        row.tap()

        XCTAssertTrue(heading("/alpha", in: app).appears(within: Ceiling.ui), "didn't switch to /alpha")
        XCTAssertTrue(app.buttons["Tabs, 2 open"].exists, "switching opened another tab")
        XCTAssertEqual(server.requestCount(for: "/alpha"), 1, "switching loaded the page again")
        withExtendedLifetime(server) {}
    }

    func testTabsTokenGoesBackToSearchingEverything() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)

        app.buttons["Tabs, 1 open"].tapWhenSettled()
        app.buttons["SwitcherSearchTabs"].tapWhenSettled()
        let token = app.buttons["Open tabs only"]
        XCTAssertTrue(token.appears(within: Ceiling.ui), "no Tabs token")
        token.tap()

        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.ui), "the field still searches tabs only")
        XCTAssertFalse(token.exists)
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "the field lost focus")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        return app
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    /// Opens `url` from the launch panel (no tabs yet) or in a new tab.
    private func open(_ url: URL, in app: XCUIApplication) {
        let field = searchField(in: app)
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(url.path(), in: app).appears(within: Ceiling.load), "\(url.path()) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
    }

    /// The bar's + panel's field, focused and empty.
    private func newTabField(in app: XCUIApplication) -> XCUIElement {
        app.buttons["NewTabPill"].tapWhenSettled()
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.ui), "+ didn't open the search panel")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value(forKey: "hasKeyboardFocus") as? Bool == true }, "field not focused")
        return field
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }
}
