import XCTest

/// The search field's edit menu pastes and loads in one step: Paste and Go, last in the menu, after
/// AutoFill. The system doesn't ask to allow the paste (the test would stop at its alert). The test
/// copies before launching, as from another app. How the item is named for what was copied, what it
/// submits, and Search Tabs offering neither, are CormorantTests' PasteAndGoTests.
@MainActor
final class PasteAndGoTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
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
