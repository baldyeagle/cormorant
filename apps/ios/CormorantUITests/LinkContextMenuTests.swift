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

    /// Picked before the preview has a page (its request for `/slow` is held back for longer than the
    /// test runs), so the new tab loads the link itself rather than adopting the preview.
    func testOpenInNewTabLoadsLinkWhenPreviewHasNoPage() throws {
        let server = try FixtureServer(html: Self.page, delays: ["/slow": 60])
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Slow page"], in: app)
        waitForHeldPreviewRequest(on: server)
        choose("Open in New Tab", in: app)

        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "didn't switch to the new tab")
        XCTAssertTrue(heading("/slow", in: app).appears(within: Ceiling.load),
                      "the new tab didn't load the link; \(server.requestLog)")
        // The preview's request and the tab's own: the tab didn't adopt the preview.
        XCTAssertEqual(server.requestCount(for: "/slow"), 2, server.requestLog)
        XCTAssertEqual(app.state, .runningForeground)
        withExtendedLifetime(server) {}
    }

    /// Picked before the preview has a page (its request for `/slow` is held back for longer than the
    /// test runs), so the tab loads it itself, in the background, and the switcher gets its snapshot
    /// without the tab ever being shown.
    func testOpenInBackgroundTabKeepsCurrentPageAndLoadsIt() throws {
        let server = try FixtureServer(html: Self.page, delays: ["/slow": 60])
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Slow page"], in: app)
        waitForHeldPreviewRequest(on: server)
        choose("Open in Background Tab", in: app)

        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no background tab")
        XCTAssertFalse(heading("/slow", in: app).appears(within: 2), "left the current page")
        XCTAssertTrue(heading("/", in: app).exists)

        // A real tab: the switcher lists it, and has its page without it ever being shown.
        openSwitcher(in: app, count: 2)
        assertSnapshots(2, in: app)
        // The preview's request and the tab's own: the tab loaded the link itself.
        XCTAssertEqual(server.requestCount(for: "/slow"), 2, server.requestLog)

        // Back on the page: still the one on screen and usable (the background stage stays behind it).
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load))
        let tabs = tabsButton(count: 2, in: app)
        XCTAssertTrue(waitUntil(Ceiling.ui) { tabs.isHittable }, "the tab button isn't usable")
        withExtendedLifetime(server) {}
    }

    /// The preview has the page: the background tab takes it over, with no second request.
    func testOpenInBackgroundTabAdoptsLoadedPreview() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenuAndWaitForPreview(on: "Next page", path: "/next", in: app)
        choose("Open in Background Tab", in: app)

        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no background tab")
        XCTAssertTrue(heading("/", in: app).exists, "left the current page")
        openSwitcher(in: app, count: 2)
        assertSnapshots(2, in: app)
        XCTAssertEqual(server.requestCount(for: "/next"), 1, "the page was loaded again")
        withExtendedLifetime(server) {}
    }

    /// The preview has the page: the new tab takes it over, with no second request.
    func testOpenInNewTabAdoptsLoadedPreview() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenuAndWaitForPreview(on: "Next page", path: "/next", in: app)
        choose("Open in New Tab", in: app)

        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "didn't switch to the new tab")
        XCTAssertTrue(heading("/next", in: app).exists)
        XCTAssertEqual(server.requestCount(for: "/next"), 1, "the page was loaded again")
        withExtendedLifetime(server) {}
    }

    /// A tab that adopted the preview's page keeps its history like any tab: across a relaunch, back
    /// returns to that first page, and (a link opened the tab) swiping back from there closes it.
    func testAdoptedTabHistorySurvivesRelaunch() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url, session: UUID().uuidString)

        openMenuAndWaitForPreview(on: "Next page", path: "/next", in: app)
        choose("Open in New Tab", in: app)
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "didn't switch to the new tab")
        XCTAssertEqual(server.requestCount(for: "/next"), 1, "the page was loaded again")
        app.webViews.links["Third page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(heading("/third", in: app).appears(within: Ceiling.load), "link didn't navigate")

        // Killed while open, once the saves made while browsing have landed (see BackSwipeCloseTests).
        XCTAssertTrue(app.savesSettle(), "the app's saves didn't finish")
        app.terminate()
        app.launch()
        XCTAssertTrue(heading("/third", in: app).appears(within: Ceiling.launch), "tab didn't come back")
        XCTAssertTrue(tabsButton(count: 2, in: app).exists)

        app.buttons["Page actions"].tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.appears(within: Ceiling.ui), "caret sheet didn't open")
        back.tap()
        XCTAssertTrue(heading("/next", in: app).appears(within: Ceiling.load), "the adopted page's entry was lost")
        XCTAssertTrue(tabsButton(count: 2, in: app).exists, "Back closed the tab instead of going back")

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(tabsButton(count: 1, in: app).appears(within: Ceiling.ui), "swipe didn't close the tab")
        withExtendedLifetime(server) {}
    }

    func testCopyLinkCopiesURL() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Next page"], in: app)
        choose("Copy Link", in: app)

        // Read back through the app (`UITestingProbes`): the test runner reading the pasteboard itself
        // would be a cross-app paste. Pasting with ⌘V instead raced the keyboard coming up.
        let pasteboard = app.descendants(matching: .any)["UITesting.pasteboard"].firstMatch
        let expected = server.url.appending(path: "next").absoluteString
        XCTAssertTrue(waitUntil(Ceiling.ui) { pasteboard.value as? String == expected },
                      "the pasteboard has \(String(describing: pasteboard.value)), not the link")
        withExtendedLifetime(server) {}
    }

    /// Tapping the preview opens the link in a new tab, which takes over the preview's page (no second
    /// request) as the card grows into it.
    func testTappingPreviewOpensNewTabWithPreviewPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        let previewHeading = openMenuAndWaitForPreview(on: "Next page", path: "/next", in: app)
        // The preview's content isn't hittable; tap where it is, once it has stopped growing.
        let frame = previewHeading.settledFrame()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()

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

    /// `target=_blank` doesn't matter to the menu: Open Link still means this tab.
    func testBlankTargetOpenLinkStaysInCurrentTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        openMenu(on: app.webViews.links["Blank target"], in: app)
        choose("Open Link", in: app)

        XCTAssertTrue(heading("/", in: app).disappears(within: Ceiling.load), "the tab didn't navigate")
        XCTAssertTrue(heading("/popup", in: app).appears(within: Ceiling.load))
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
        XCTAssertTrue(alert.appears(within: Ceiling.ui), "no confirmation before opening Mail")
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
        dismissMenu(in: app)

        let plain = app.webViews.images["Plain image"]
        longPressForMenu(plain, in: app)
        XCTAssertFalse(app.buttons["Copy Link"].appears(within: 2), "a plain image got the link menu")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// Launches with no saved tabs and opens `url` from the launch search panel.
    /// `session` keeps the app's saved tabs across relaunches of `app`.
    private func launchOnPage(_ url: URL, session: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        if let session { app.launchEnvironment["CORMORANT_UI_TESTING_SESSION"] = session }
        app.launch()

        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        field.typeText(url.absoluteString + "\n")
        // Generous: the first page load on a fresh simulator is slow.
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "fixture page didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
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
        tabsButton(count: count, in: app).tap()
        XCTAssertTrue(app.staticTexts["\(count) Tabs"].appears(within: Ceiling.ui), "switcher didn't open", file: file, line: line)
    }

    /// Waits until the preview has asked for `/slow`, the request the server holds back, so the tab's
    /// own request (answered at once) can't be the first one instead.
    private func waitForHeldPreviewRequest(on server: FixtureServer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(Ceiling.load) { server.requestCount(for: "/slow") == 1 },
                      "the preview didn't request /slow; \(server.requestLog)", file: file, line: line)
    }

    /// Waits for `count` switcher cards to show their page rather than a placeholder.
    private func assertSnapshots(_ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let snapshots = app.descendants(matching: .any).matching(identifier: "TabCard.snapshot")
        let shown = waitUntil(Ceiling.load) { snapshots.count == count }
        if !shown {
            XCTFail("\(snapshots.count) of \(count) tabs have a snapshot", file: file, line: line)
        }
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

    /// Taps outside the menu, near the top of the screen.
    private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(app.buttons["Copy Link"].disappears(within: Ceiling.ui), "menu didn't close")
        app.waitsForAnimations = true
    }

    /// Long-presses `element` once, for checks that no menu comes up (`openMenu` waits for one), with
    /// XCTest's animation wait off until the menu has closed again (see
    /// `XCUIApplication.waitsForAnimations`); `choose` and `dismissMenu` turn it back on.
    private func longPressForMenu(_ element: XCUIElement, in app: XCUIApplication) {
        app.waitsForAnimations = false
        element.press(forDuration: 1.5)
    }
}
