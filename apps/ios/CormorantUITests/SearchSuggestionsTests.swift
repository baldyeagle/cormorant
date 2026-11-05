import XCTest

/// The search panel suggests from history and open tabs: the field completes to a visited site,
/// history rows reopen pages, open tabs offer to switch rather than load again, and Search Tabs
/// limits the panel to open tabs.
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

    func testHistoryRowReopensAPageNoTabShows() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)
        // The same tab moves on, so /alpha is only in history.
        app.buttons["NewTabPill"].tapWhenSettled()
        let edit = app.buttons["Edit address: Page alpha"]
        XCTAssertTrue(edit.appears(within: Ceiling.ui), "no Edit row")
        edit.tap()
        let field = searchField(in: app)
        field.typeText(server.url.appending(path: "beta").absoluteString + "\n")
        XCTAssertTrue(heading("/beta", in: app).appears(within: Ceiling.load), "/beta didn't load")

        newTabField(in: app).typeText("alpha")
        let row = app.buttons.matching(NSPredicate(format: "label == 'Page alpha' AND value ENDSWITH 'history'")).firstMatch
        XCTAssertTrue(row.appears(within: Ceiling.ui), "no history row for /alpha")
        row.tap()

        XCTAssertTrue(heading("/alpha", in: app).appears(within: Ceiling.load), "the history row didn't load /alpha")
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui), "composing, the row didn't open a new tab")
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
        // Shown once, and stays so once history has answered: the open tab hides its history entry.
        XCTAssertFalse(waitUntil(2) { app.buttons.matching(NSPredicate(format: "label == 'Page alpha'")).count != 1 },
                       "/alpha is listed twice")
        row.tap()

        XCTAssertTrue(heading("/alpha", in: app).appears(within: Ceiling.ui), "didn't switch to /alpha")
        XCTAssertFalse(app.buttons["Tabs, 3 open"].appears(within: 2), "switching opened another tab")
        XCTAssertEqual(server.requestCount(for: "/alpha"), 1, "switching loaded the page again")
        withExtendedLifetime(server) {}
    }

    func testSearchTabsFromTheSwitcher() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)
        newTabField(in: app).typeText(server.url.appending(path: "beta").absoluteString + "\n")
        XCTAssertTrue(heading("/beta", in: app).appears(within: Ceiling.load), "/beta didn't load")

        app.buttons["Tabs, 2 open"].tapWhenSettled()
        let search = app.toolbars.buttons["Search Tabs"]
        XCTAssertTrue(search.appears(within: Ceiling.ui), "no Search Tabs in the switcher")
        search.tapWhenSettled()

        let field = app.textFields["Search open tabs"]
        XCTAssertTrue(field.appears(within: Ceiling.ui), "Search Tabs didn't open the panel")
        XCTAssertTrue(app.buttons["Open tabs only"].exists, "no Tabs token")
        // Every open tab, the current one too.
        XCTAssertTrue(app.staticTexts["2 Open Tabs"].appears(within: Ceiling.ui), "the panel doesn't list both tabs")
        field.typeText("alph")
        XCTAssertTrue(app.staticTexts["2 Open Tabs · 1 match"].appears(within: Ceiling.ui), "the tabs weren't filtered")
        field.typeText("\n")

        XCTAssertTrue(heading("/alpha", in: app).appears(within: Ceiling.ui), "Go didn't switch to the match")
        XCTAssertTrue(app.buttons["Tabs, 2 open"].exists, "Go opened a tab")
        XCTAssertEqual(server.requestCount(for: "/alpha"), 1, "switching loaded the page again")
        withExtendedLifetime(server) {}
    }

    func testTabsTokenGoesBackToSearchingEverything() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "alpha"), in: app)

        app.buttons["Tabs, 1 open"].tapWhenSettled()
        app.toolbars.buttons["Search Tabs"].tapWhenSettled()
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
