import XCTest

/// New Tab must bring up the search panel even after the page has been tapped. Tapping makes the
/// web view first responder; the dismissing tab switcher then handed focus back to it, the search
/// field lost focus as soon as it got it, and the panel closed: New Tab appeared to do nothing.
@MainActor
final class NewTabTests: XCTestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1>Fixture page</h1>
        <p>Tap this paragraph so the web view becomes first responder.</p>
        """

    func testNewTabFromSwitcherAfterTappingPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.buttons["Tabs, 1 open"].tap()
        let newTab = app.buttons["New Tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.tap()

        assertSearchPanelStaysUp(in: app)
        withExtendedLifetime(server) {}
    }

    /// The menu path didn't reproduce the bug in the simulator; this keeps it covered all the same.
    func testNewTabFromTabButtonMenuAfterTappingPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)
        let tabs = app.buttons["Tabs, 1 open"]
        let item = app.buttons["New Tab"]

        // A synthesized tap doesn't activate menu items on the iOS 27 simulator (the menu stays up),
        // so choose it the other way a finger can: hold the button, slide onto the item, lift. Open
        // the menu once to find where the item sits, then close it with a tap on the page.
        tabs.press(forDuration: 1)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "long-press didn't open the menu")
        // Measured once it has settled, not while the menu is still springing open.
        let settled = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: item)
        wait(for: [settled], timeout: 5)
        let itemCenter = CGPoint(x: item.frame.midX, y: item.frame.midY)
        app.webViews.staticTexts["Fixture page"].tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "menu didn't close")

        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = tabs.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2, thenDragTo: origin.withOffset(CGVector(dx: itemCenter.x, dy: itemCenter.y)))

        assertSearchPanelStaysUp(in: app)
        withExtendedLifetime(server) {}
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

    private func assertSearchPanelStaysUp(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "New Tab didn't open the search panel", file: file, line: line)
        // The bug closed it within a moment of opening; hold well past that.
        XCTAssertFalse(field.waitForNonExistence(timeout: 2), "search panel closed by itself", file: file, line: line)
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true,
                       "search field lost focus", file: file, line: line)
    }
}
