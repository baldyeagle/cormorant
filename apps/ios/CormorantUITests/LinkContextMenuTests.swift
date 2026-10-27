import XCTest

/// The long-press link menu. Open Link used to go through the system's link menu, which handed the
/// URL to the default browser; every action here must stay in Cormorant.
@MainActor
final class LinkContextMenuTests: XCTestCase {
    /// Every path serves this page; its heading names the path it was loaded at.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        <a href="/next">Next page</a>
        <a href="/popup" target="_blank">Blank target</a>
        <a href="mailto:someone@example.com">Mail link</a>
        <a href="javascript:void(0)">Script link</a>
        <a href="data:text/html,<h1>Data page</h1>">Data link</a>
        <a href="/pictured"><img alt="Linked image" width="160" height="90" src="\(pixel)"></a>
        <p><img alt="Plain image" width="160" height="90" src="\(pixel)"></p>
        """
    private static let pixel = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

    func testOpenLinkNavigatesCurrentTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        choose("Open Link", in: app)

        // The preview shows the next page too; the old one going is what proves the tab navigated.
        XCTAssertTrue(heading("/", in: app).waitForNonExistence(timeout: 10), "Open Link didn't navigate this tab")
        XCTAssertTrue(heading("/next", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground, "Open Link left Cormorant")
        XCTAssertTrue(tabsButton(count: 1, in: app).exists, "Open Link changed the tab count")
        withExtendedLifetime(server) {}
    }

    func testOpenInNewTabSwitchesToIt() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        choose("Open in New Tab", in: app)

        XCTAssertTrue(tabsButton(count: 2, in: app).waitForExistence(timeout: 5), "no new tab")
        XCTAssertTrue(heading("/", in: app).waitForNonExistence(timeout: 10), "didn't switch to the new tab")
        XCTAssertTrue(heading("/next", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        withExtendedLifetime(server) {}
    }

    func testOpenInBackgroundTabKeepsCurrentPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        choose("Open in Background Tab", in: app)

        XCTAssertTrue(tabsButton(count: 2, in: app).waitForExistence(timeout: 5), "no background tab")
        XCTAssertFalse(heading("/next", in: app).waitForExistence(timeout: 2), "left the current page")
        XCTAssertTrue(heading("/", in: app).exists)

        // It's a real tab: the switcher lists it.
        tabsButton(count: 2, in: app).tap()
        XCTAssertTrue(app.toolbars.buttons["New Tab"].waitForExistence(timeout: 5), "switcher didn't open")
        XCTAssertTrue(app.staticTexts["2 Tabs"].waitForExistence(timeout: 5), "switcher doesn't count it")
        XCTAssertEqual(app.buttons.matching(identifier: "xmark.circle.fill").count, 2, "switcher doesn't show it")
        withExtendedLifetime(server) {}
    }

    func testCopyLinkCopiesURL() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        choose("Copy Link", in: app)

        // Read it back by pasting into a new tab's empty address field: the test runner reading the
        // pasteboard directly would be a cross-app paste.
        app.buttons["NewTabPill"].tap()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search panel didn't open")
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        wait(for: [focused], timeout: 5)
        field.typeKey("v", modifierFlags: .command)
        let expected = server.url.appending(path: "next").absoluteString
        let pasted = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: field)
        wait(for: [pasted], timeout: 5)
        withExtendedLifetime(server) {}
    }

    /// Like Safari: tapping the preview opens the link here.
    func testTappingPreviewOpensLinkInCurrentTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        let previewHeading = heading("/next", in: app)
        XCTAssertTrue(previewHeading.waitForExistence(timeout: 10), "the preview didn't load the page")
        // The preview's content isn't hittable; tap where it is.
        let frame = previewHeading.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()

        XCTAssertTrue(app.buttons["Open Link"].waitForNonExistence(timeout: 5), "menu didn't close")
        XCTAssertTrue(heading("/next", in: app).waitForExistence(timeout: 10), "the tab didn't navigate")
        XCTAssertTrue(heading("/", in: app).waitForNonExistence(timeout: 5), "still on the old page")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(tabsButton(count: 1, in: app).exists)
        withExtendedLifetime(server) {}
    }

    /// `target=_blank` doesn't matter to the menu: Open Link still means this tab.
    func testBlankTargetOpenLinkStaysInCurrentTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Blank target"], in: app)
        choose("Open Link", in: app)

        XCTAssertTrue(heading("/", in: app).waitForNonExistence(timeout: 10), "the tab didn't navigate")
        XCTAssertTrue(heading("/popup", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(tabsButton(count: 1, in: app).exists)
        withExtendedLifetime(server) {}
    }

    /// Another app's link can't load in a tab; Open Link asks first, as a tap does.
    func testMailLinkOffersNoTabsAndAsksBeforeOpening() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Mail link"], in: app)
        XCTAssertTrue(app.buttons["Copy Link"].exists)
        XCTAssertFalse(app.buttons["Open in New Tab"].exists)
        XCTAssertFalse(app.buttons["Open in Background Tab"].exists)
        choose("Open Link", in: app)

        let alert = app.alerts["Open in Mail?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirmation before opening Mail")
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(app.state, .runningForeground)
        withExtendedLifetime(server) {}
    }

    /// A tap can't open a data: URL top-level, so the menu doesn't either.
    func testDataLinkOffersCopyOnly() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Data link"], in: app)
        XCTAssertTrue(app.buttons["Share Link"].exists)
        XCTAssertFalse(app.buttons["Open Link"].exists)
        XCTAssertFalse(app.buttons["Open in New Tab"].exists)
        withExtendedLifetime(server) {}
    }

    func testScriptLinkHasNoMenu() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Script link"].press(forDuration: 1.5)
        XCTAssertFalse(app.buttons["Open Link"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Open Link in Default Browser"].exists)
        withExtendedLifetime(server) {}
    }

    /// A linked image gets the link menu; a plain image doesn't (it has no link URL).
    func testImages() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Linked image"].firstMatch, in: app)
        XCTAssertTrue(app.buttons["Open in Background Tab"].exists)
        XCTAssertTrue(app.buttons["Copy Link"].exists)
        dismissMenu(in: app)

        let plain = app.webViews.images["Plain image"]
        plain.press(forDuration: 1.5)
        XCTAssertFalse(app.buttons["Copy Link"].waitForExistence(timeout: 2), "a plain image got the link menu")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// Launches with no saved tabs and opens `url` from the launch search panel.
    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        // On the iOS 27.1 simulator a context menu never reports its animations idle, so every query
        // after a long-press waited out a 60-second timeout. Skip only that wait; the app must still
        // be idle on its main thread. Private, so a no-op if XCTest drops it.
        if app.responds(to: NSSelectorFromString("setIdleAnimationWaitEnabled:")) {
            app.setValue(false, forKey: "idleAnimationWaitEnabled")
        }
        app.launch()

        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search panel at launch")
        field.typeText(url.absoluteString + "\n")
        // Generous: a fresh simulator is also downloading and compiling the filter lists meanwhile.
        XCTAssertTrue(heading("/", in: app).waitForExistence(timeout: 30), "fixture page didn't load")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "search panel didn't close on submit")
        return app
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    private func tabsButton(count: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["Tabs, \(count) open"]
    }

    private func openMenu(on element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "nothing to long-press", file: file, line: line)
        element.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Copy Link"].waitForExistence(timeout: 5), "no link menu", file: file, line: line)
        // The system menu offered this; ours never does.
        XCTAssertFalse(app.buttons["Add to Reading List"].exists, "the system link menu came up", file: file, line: line)
    }

    private func choose(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(title) item", file: file, line: line)
        let settled = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: item)
        wait(for: [settled], timeout: 5)
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "menu didn't close after \(title)", file: file, line: line)
    }

    /// Taps outside the menu, near the top of the screen.
    private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(app.buttons["Copy Link"].waitForNonExistence(timeout: 5), "menu didn't close")
    }
}
