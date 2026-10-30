import XCTest

/// New Tab must bring up the search panel even after the page has been tapped. Tapping makes the
/// web view first responder; the dismissing tab switcher then handed focus back to it, the search
/// field lost focus as soon as it got it, and the panel closed: New Tab appeared to do nothing.
///
/// The bar's + composes a new tab; the panel's row for the tab it came from edits that tab instead.
@MainActor
final class NewTabTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop at the first failure: what follows would only wait out its ceilings, or 60 s per
        // query if a link menu was left up with the animation wait off.
        continueAfterFailure = false
    }

    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1>Fixture page</h1>
        <p>Tap this paragraph so the web view becomes first responder.</p>
        <p id="path">Path</p>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        """

    func testNewTabFromSwitcherAfterTappingPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.buttons["Tabs, 1 open"].tap()
        let newTab = app.toolbars.buttons["New Tab"]
        XCTAssertTrue(newTab.appears(within: Ceiling.ui))
        newTab.tap()

        assertSearchPanelStaysUp(in: app)
        withExtendedLifetime(server) {}
    }

    /// The menu path didn't reproduce the bug in the simulator; this keeps it covered all the same.
    func testNewTabFromTabButtonMenuAfterTappingPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)
        let tabs = app.buttons["Tabs, 1 open"]
        let item = app.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier != 'NewTabPill'")).firstMatch

        // A synthesized tap doesn't activate menu items on the iOS 27 simulator (the menu stays up),
        // so choose it the other way a finger can: hold the button, slide onto the item, lift. Open
        // the menu once to find where the item sits, then close it with a tap on the page.
        tabs.press(forDuration: 1)
        XCTAssertTrue(item.appears(within: Ceiling.ui), "long-press didn't open the menu")
        // Measured once it has settled, not while the menu is still springing open.
        XCTAssertTrue(waitUntil(Ceiling.ui) { item.isHittable }, "the menu didn't settle")
        let itemFrame = item.settledFrame()
        let itemCenter = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        app.webViews.staticTexts["Fixture page"].tap()
        XCTAssertTrue(item.disappears(within: Ceiling.ui), "menu didn't close")

        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = tabs.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2, thenDragTo: origin.withOffset(CGVector(dx: itemCenter.x, dy: itemCenter.y)))

        assertSearchPanelStaysUp(in: app)
        withExtendedLifetime(server) {}
    }

    func testNewTabPillOpensANewTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.buttons["NewTabPill"].tap()
        assertSearchPanelStaysUp(in: app)
        // An empty field reports its placeholder as its value.
        let field = searchField(in: app)
        XCTAssertEqual(field.value as? String, field.placeholderValue, "a new tab's field isn't empty")
        field.typeText(server.url.appending(path: "next").absoluteString + "\n")

        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui), "+ didn't open a new tab")
        XCTAssertTrue(app.webViews.staticTexts["Path /next"].appears(within: Ceiling.load), "the new tab didn't load")
        withExtendedLifetime(server) {}
    }

    func testEditRowEditsTheCurrentTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.buttons["NewTabPill"].tap()
        assertSearchPanelStaysUp(in: app)
        let row = app.buttons["Edit address: Fixture"]
        XCTAssertTrue(row.appears(within: Ceiling.ui), "no row for the current tab")
        row.tap()

        // The panel stays up with this tab's address in the field, selected, so typing replaces it.
        let field = searchField(in: app)
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value as? String == server.url.absoluteString }, "the field doesn't have the tab's address")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "search field lost focus")
        let next = server.url.appending(path: "next").absoluteString
        field.typeText(next)
        XCTAssertEqual(field.value as? String, next, "the address wasn't selected, so typing didn't replace it")
        field.typeText("\n")

        XCTAssertTrue(app.webViews.staticTexts["Path /next"].appears(within: Ceiling.load), "the tab didn't navigate")
        XCTAssertFalse(app.buttons["Tabs, 2 open"].appears(within: 2), "editing opened a new tab")
        XCTAssertTrue(app.buttons["Tabs, 1 open"].exists)
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
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        field.typeText(url.absoluteString + "\n")

        let paragraph = app.webViews.staticTexts["Tap this paragraph so the web view becomes first responder."]
        // Generous: the first page load on a fresh simulator is slow.
        XCTAssertTrue(paragraph.appears(within: Ceiling.load), "fixture page didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        paragraph.tap()
        return app
    }

    private func assertSearchPanelStaysUp(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.ui), "New Tab didn't open the search panel", file: file, line: line)
        // The bug closed it within a moment of opening; hold well past that.
        XCTAssertFalse(field.disappears(within: 2), "search panel closed by itself", file: file, line: line)
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true,
                       "search field lost focus", file: file, line: line)
    }
}
