import XCTest

/// The caret sheet's handoffs: the host opens the search panel, and Settings stacks on the sheet
/// rather than replacing it.
@MainActor
final class CaretSheetTests: XCTestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1>Fixture page</h1>
        <p>Tap this paragraph so the web view becomes first responder.</p>
        """

    /// The panel opens while the sheet slides away. Without `presentActions()` resigning first, the
    /// dismissing sheet handed first responder back to the tapped web view and the panel closed.
    func testHostOpensSearchPanelAfterTappingPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openCaretSheet(in: app)
        sheetHost(in: app).tap()

        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the host didn't open the search panel")
        XCTAssertFalse(field.waitForNonExistence(timeout: 2), "search panel closed by itself")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "search field lost focus")
        withExtendedLifetime(server) {}
    }

    func testSettingsDoneReturnsToCaretSheet() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openCaretSheet(in: app)
        openSettingsAndClose(in: app)

        XCTAssertTrue(app.buttons["Find on Page"].waitForExistence(timeout: 5), "caret sheet went away with Settings")
        withExtendedLifetime(server) {}
    }

    /// With no page, a search field must come back once nothing else is up (default-browser rule).
    func testEmptyStateSettingsThenCaretSheetCloseBringsSearchBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search panel at launch")
        app.buttons["Close search"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "search panel didn't close")

        openCaretSheet(in: app)
        openSettingsAndClose(in: app)
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "caret sheet went away with Settings")

        // Swipe the caret sheet away by its grabber.
        let grabber = app.descendants(matching: .any)["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "caret sheet didn't close")

        // `actionsDidDismiss` runs a second or more after the sheet has gone.
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search panel after the sheets closed")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "search field has no focus")
    }

    // MARK: Helpers

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    /// Launches with no saved tabs, opens `url` from the launch search panel, and taps the page.
    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search panel at launch")
        field.typeText(url.absoluteString + "\n")

        let paragraph = app.webViews.staticTexts["Tap this paragraph so the web view becomes first responder."]
        // Generous: a fresh simulator is also downloading and compiling the filter lists meanwhile.
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30), "fixture page didn't load")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "search panel didn't close on submit")
        paragraph.tap()
        return app
    }

    private func openCaretSheet(in app: XCUIApplication) {
        app.buttons["Page actions"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "caret sheet didn't open")
    }

    /// The sheet's host button. The bar's pill has the same label, so pick the one above the tiles.
    private func sheetHost(in app: XCUIApplication) -> XCUIElement {
        let tiles = app.buttons["Find on Page"]
        XCTAssertTrue(tiles.waitForExistence(timeout: 5))
        let hosts = app.buttons.matching(NSPredicate(format: "label == 'Address'")).allElementsBoundByIndex
        return hosts.first { $0.frame.maxY <= tiles.frame.minY } ?? hosts[0]
    }

    private func openSettingsAndClose(in app: XCUIApplication) {
        app.buttons["Settings"].tap()
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings didn't open")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Settings didn't close")
    }
}
