import XCTest

/// The long-press link menu. Open Link used to go through the system's link menu, which handed the
/// URL to the default browser; every action here must stay in Cormorant.
@MainActor
final class LinkContextMenuTests: UITestCase {
    /// Every path serves this page; its heading names the path it was loaded at.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        <a href="/next">Next page</a>
        <a href="/slow">Slow page</a>
        <a href="/third">Third page</a>
        <a href="/popup" target="_blank">Blank target</a>
        <a href="mailto:someone@example.com">Mail link</a>
        <a href="javascript:void(0)">Script link</a>
        <a href="data:text/html,<h1>Data page</h1>">Data link</a>
        <a href="/pictured"><img alt="Linked image" width="160" height="90" src="\(pixel)"></a>
        <p><img alt="Plain image" width="160" height="90" src="\(pixel)"></p>
        \(selectionReport)
        """
    private static let pixel = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

    func testOpenLinkNavigatesCurrentTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        choose("Open Link", in: app)

        // The preview shows the next page too; the old one going is what proves the tab navigated.
        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "Open Link didn't navigate this tab")
        XCTAssertTrue(heading("/next", in: app).appears(within: Ceiling.load))
        XCTAssertEqual(app.state, .runningForeground, "Open Link left Cormorant")
        XCTAssertTrue(tabsButton(count: 1, in: app).exists, "Open Link changed the tab count")
        withExtendedLifetime(server) {}
    }

    /// Tapping the preview opens the link in a new tab, which takes over the preview's page (no second
    /// request) as the card grows into it.
    func testTappingPreviewOpensNewTabWithPreviewPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenuAndWaitForPreview(on: "Next page", path: "/next", in: app)
        tapLinkPreview(in: app)

        XCTAssertTrue(app.buttons["Open Link"].disappears(within: Ceiling.ui), "menu didn't close")
        app.waitsForAnimations = true
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "still on the old page")
        XCTAssertTrue(heading("/next", in: app).appears(within: Ceiling.load), "the new tab has no page")
        XCTAssertEqual(server.requestCount(for: "/next"), 1, "the page was loaded again")
        XCTAssertEqual(app.state, .runningForeground)
        // Nothing is left over the page (the growing card is hidden from accessibility, so only a tap
        // shows it's gone): the bar answers.
        openSwitcher(in: app, count: 2)
        withExtendedLifetime(server) {}
    }

    /// Tapping a switcher card opens its tab (it grows into the page with `CardExpansion`, as a tapped
    /// link preview does).
    func testSwitcherCardOpensItsTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenuAndWaitForPreview(on: "Next page", path: "/next", in: app)
        choose("Open in New Tab", in: app)
        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "didn't switch to the new tab")

        openSwitcher(in: app, count: 2)
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'TabCard'"))
        XCTAssertTrue(waitUntil(Ceiling.ui) { cards.count == 2 }, "the switcher doesn't show both cards")
        // The opener's card: the one that isn't selected (the new tab is the active one).
        let opener = cards.allElementsBoundByIndex.first { !$0.isSelected }
        let card = try XCTUnwrap(opener, "no card for the opener")
        // Its left part: the stack starts scrolled to the newest card, which overlaps the opener's right.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "the card didn't open its tab")
        XCTAssertTrue(app.staticTexts["2 Tabs"].disappears(within: Ceiling.ui), "the switcher stayed up")
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui))
        withExtendedLifetime(server) {}
    }

    func testScriptLinkHasNoMenu() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        longPressForMenu(app.webViews.links["Script link"], in: app)
        XCTAssertFalse(app.buttons["Open Link"].appears(within: 2))
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
        dismissLinkMenu(beside: app.buttons["Copy Link"], in: app)

        let plain = app.webViews.images["Plain image"]
        longPressForMenu(plain, in: app)
        XCTAssertFalse(app.buttons["Copy Link"].appears(within: 2), "a plain image got the link menu")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// Launches with no saved tabs but one on `url`.
    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        // On the page from the start (`-uiTestingOpen`): no typing, no keyboard to wait out.
        app.launchArguments = ["-uiTesting", "-uiTestingOpen", url.absoluteString]
        app.launch()
        // Generous: the first page load on a fresh simulator is slow.
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "fixture page didn't load")
        return app
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    private func tabsButton(count: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["Tabs, \(count) open"]
    }

    private func openMenu(on element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(within: Ceiling.load), "nothing to long-press", file: file, line: line)
        XCTAssertTrue(pressForLinkMenu(element, until: app.buttons["Copy Link"], in: app), "no link menu",
                      file: file, line: line)
        // The system menu offered this; ours never does.
        XCTAssertFalse(app.buttons["Add to Reading List"].exists, "the system link menu came up", file: file, line: line)
    }

    /// Opens the menu on the link titled `link` and waits for its preview to show `path`'s page.
    @discardableResult
    private func openMenuAndWaitForPreview(on link: String, path: String, in app: XCUIApplication,
                                           file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        openMenu(on: app.webViews.links[link], in: app, file: file, line: line)
        let previewHeading = heading(path, in: app)
        XCTAssertTrue(previewHeading.appears(within: Ceiling.load), "the preview didn't load the page", file: file, line: line)
        return previewHeading
    }

    private func openSwitcher(in app: XCUIApplication, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        tabsButton(count: count, in: app).tapWhenSettled()
        XCTAssertTrue(app.staticTexts["\(count) Tabs"].appears(within: Ceiling.ui), "switcher didn't open", file: file, line: line)
    }

    private func choose(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.buttons[title]
        XCTAssertTrue(item.appears(within: Ceiling.ui), "no \(title) item", file: file, line: line)
        XCTAssertTrue(waitUntil(Ceiling.ui) { item.isHittable }, "\(title) isn't hittable", file: file, line: line)
        // Hittable while the menu is still springing open, when UIKit takes a tap as a dismissal (no
        // action); wait for the item to stop moving.
        item.tapWhenSettled()
        XCTAssertTrue(item.disappears(within: Ceiling.ui), "menu didn't close after \(title)", file: file, line: line)
        app.waitsForAnimations = true
    }

    /// Long-presses `element` once, for checks that no menu comes up (`openMenu` waits for one), with
    /// XCTest's animation wait off until the menu has closed again (see
    /// `XCUIApplication.waitsForAnimations`); `choose` and `dismissLinkMenu` turn it back on.
    private func longPressForMenu(_ element: XCUIElement, in app: XCUIApplication) {
        app.waitsForAnimations = false
        element.press(forDuration: 1.5)
    }
}
