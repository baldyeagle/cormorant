import XCTest

/// The search field's edit menu pastes and loads in one step, named for what was copied: Paste and
/// Go for an address, Paste and Search for other text. The system doesn't ask to allow the paste
/// (the test would stop at its alert). Each test copies before launching, as from another app.
@MainActor
final class PasteAndGoTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <p id="query"></p>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname;
          const query = new URLSearchParams(location.search).get('q');
          if (query) document.getElementById('query').textContent = 'Query ' + query;
        </script>
        """

    func testPasteAndGoLoadsACopiedAddress() throws {
        let server = try FixtureServer(html: Self.page)
        UIPasteboard.general.string = server.url.appending(path: "pasted").absoluteString
        let app = launch()

        choose("Paste and Go", over: "Paste and Search", in: app)

        XCTAssertTrue(heading("/pasted", in: app).appears(within: Ceiling.load), "Paste and Go didn't load the copied address")
        XCTAssertTrue(searchField(in: app).disappears(within: Ceiling.ui), "search panel didn't close")
        withExtendedLifetime(server) {}
    }

    func testPasteAndSearchSearchesCopiedText() throws {
        let server = try FixtureServer(html: Self.page)
        UIPasteboard.general.string = "cormorant\nbird facts"
        let app = launch(searchingAt: server.url.absoluteString + "search?q={query}")

        choose("Paste and Search", over: "Paste and Go", in: app)

        XCTAssertTrue(app.webViews.staticTexts["Query cormorant bird facts"].firstMatch.appears(within: Ceiling.load),
                      "Paste and Search didn't search for the copied text")
        XCTAssertTrue(searchField(in: app).disappears(within: Ceiling.ui), "search panel didn't close")
        withExtendedLifetime(server) {}
    }

    /// Searching open tabs only, Return picks a tab, so neither item is offered; back to searching
    /// everything, Paste and Go is.
    func testSearchTabsOffersNeither() throws {
        let server = try FixtureServer(html: Self.page)
        UIPasteboard.general.string = server.url.appending(path: "pasted").absoluteString
        let app = launch()
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel")
        field.typeText(server.url.appending(path: "open").absoluteString + "\n")
        XCTAssertTrue(heading("/open", in: app).appears(within: Ceiling.load), "/open didn't load")
        app.buttons["Tabs, 1 open"].tapWhenSettled()
        app.buttons["SwitcherSearchTabs"].tapWhenSettled()

        let tabsField = app.textFields["Search open tabs"]
        XCTAssertTrue(tabsField.appears(within: Ceiling.ui), "Search Tabs didn't open the panel")
        XCTAssertTrue(waitUntil(Ceiling.ui) { tabsField.value(forKey: "hasKeyboardFocus") as? Bool == true }, "field not focused")
        tabsField.press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Paste"].appears(within: Ceiling.ui), "no edit menu")
        XCTAssertFalse(app.menuItems["Paste and Go"].exists, "Paste and Go offered searching tabs")
        XCTAssertFalse(app.menuItems["Paste and Search"].exists, "Paste and Search offered searching tabs")

        app.buttons["Open tabs only"].tapWhenSettled()
        choose("Paste and Go", over: "Paste and Search", in: app)
        XCTAssertTrue(heading("/pasted", in: app).appears(within: Ceiling.load), "Paste and Go didn't load the copied address")
        withExtendedLifetime(server) {}
    }

    /// Copied as text, without a scheme, an address is still told from a search.
    func testPasteAndGoTellsAnAddressInText() throws {
        let server = try FixtureServer(html: Self.page)
        UIPasteboard.general.string = "127.0.0.1:\(server.url.port!)/text"
        let app = launch()

        choose("Paste and Go", over: "Paste and Search", in: app)

        XCTAssertTrue(heading("/text", in: app).appears(within: Ceiling.load), "Paste and Go didn't load the copied address")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// `template`, if given, is the search engine (`{query}` for the query).
    private func launch(searchingAt template: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (template.map { ["-uiTestingSearchEngine", $0] } ?? [])
        app.launch()
        return app
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    /// Opens the focused field's edit menu and chooses `item`, checking it comes last (after AutoFill,
    /// as in Safari) and `other` isn't offered with it.
    private func choose(_ item: String, over other: String, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel", file: file, line: line)
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "field not focused", file: file, line: line)
        field.press(forDuration: 1)
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.appears(within: Ceiling.ui), "no \(item) in the field's menu", file: file, line: line)
        XCTAssertFalse(app.menuItems[other].exists, "\(other) offered instead", file: file, line: line)
        XCTAssertEqual(app.menuItems.allElementsBoundByIndex.last?.label, item, "\(item) isn't last", file: file, line: line)
        menuItem.tapWhenSettled()
    }
}
