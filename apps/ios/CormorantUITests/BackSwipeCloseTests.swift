import XCTest

/// Arc's back-to-close: swiping in from the left edge on the first page of a tab a link opened
/// closes it and returns to the tab viewed before it. Before that, the swipe is WebKit's back.
@MainActor
final class BackSwipeCloseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop at the first failure: what follows would only wait out its ceilings, or 60 s per
        // query if a link menu was left up with the animation wait off.
        continueAfterFailure = false
    }

    /// Every path serves this page; its heading names the path it was loaded at.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        <a href="/next">Next page</a>
        <a href="/third">Third page</a>
        <a href="/popup" target="_blank">Blank target</a>
        """

    /// Open in New Tab, follow a link there, back, back: the second back closes the tab.
    /// Synthesized drags don't drive WKWebView's own back swipe (none of press-and-drag or swipeRight
    /// did on the iOS 27.1 simulator), so the history step uses the caret sheet's Back; the swipe there
    /// is checked only for leaving the tab open.
    func testSwipeBackClosesTabOpenedFromMenuOnlyOnItsFirstPage() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        let link = app.webViews.links["Next page"]
        XCTAssertTrue(link.appears(within: Ceiling.load))
        // XCTest's animation wait off while the menu is up (see `XCUIApplication.waitsForAnimations`).
        app.waitsForAnimations = false
        link.press(forDuration: 1.5)
        let item = app.buttons["Open in New Tab"]
        XCTAssertTrue(item.appears(within: Ceiling.ui), "no link menu")
        XCTAssertTrue(waitUntil(Ceiling.ui) { item.isHittable }, "link menu didn't settle")
        item.tapWhenSettled()
        XCTAssertTrue(item.disappears(within: Ceiling.ui), "menu didn't close")
        app.waitsForAnimations = true
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/next", in: app).appears(within: Ceiling.load))

        app.webViews.links["Third page"].tap()
        XCTAssertTrue(heading("/third", in: app).appears(within: Ceiling.load), "link didn't navigate")

        swipeBackFromLeftEdge(in: app)
        XCTAssertFalse(tabsButton(count: 2, in: app).disappears(within: 2), "closed a tab that can go back")

        app.buttons["Page actions"].tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.appears(within: Ceiling.ui), "caret sheet didn't open")
        back.tap()
        XCTAssertTrue(heading("/next", in: app).appears(within: Ceiling.load), "Back didn't go back")
        XCTAssertTrue(tabsButton(count: 2, in: app).exists, "Back closed the tab instead of going back")

        swipeBackFromLeftEdge(in: app)
        XCTAssertTrue(tabsButton(count: 1, in: app).appears(within: Ceiling.ui), "swipe didn't close the tab")
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    func testSwipeBackClosesBlankTargetTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/popup", in: app).appears(within: Ceiling.load))

        swipeBackFromLeftEdge(in: app)
        XCTAssertTrue(tabsButton(count: 1, in: app).appears(within: Ceiling.ui), "swipe didn't close the tab")
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    /// A tab's back history survives the app being killed and relaunched, as in Arc: back still goes
    /// to the link-opened tab's first page, and only then closes it. Also covers the opener tab, which
    /// isn't shown after the relaunch until the close lands on it.
    func testHistorySurvivesRelaunch() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url, session: UUID().uuidString)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/popup", in: app).appears(within: Ceiling.load))
        // By position: on the iOS 27.1 simulator XCUITest reported this link as not hittable at rest.
        app.webViews.links["Third page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(heading("/third", in: app).appears(within: Ceiling.load), "link didn't navigate")

        // Killed while open, the harder case: only the saves made while browsing (once a page has
        // loaded) have run, not the one when the app goes away (swiped away from the app switcher).
        // Killed once those have landed, which the app reports under -uiTesting.
        XCTAssertTrue(app.savesSettle(), "the app's saves didn't finish")
        app.terminate()
        app.launch()
        XCTAssertTrue(heading("/third", in: app).appears(within: Ceiling.launch), "tab didn't come back")
        XCTAssertTrue(tabsButton(count: 2, in: app).exists)

        app.buttons["Page actions"].tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.appears(within: Ceiling.ui), "caret sheet didn't open")
        back.tap()
        XCTAssertTrue(heading("/popup", in: app).appears(within: Ceiling.load), "history was lost on relaunch")
        XCTAssertTrue(tabsButton(count: 2, in: app).exists, "Back closed the tab instead of going back")

        swipeBackFromLeftEdge(in: app)
        XCTAssertTrue(tabsButton(count: 1, in: app).appears(within: Ceiling.ui), "swipe didn't close the tab")
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    /// Let go early and the page springs back; the tab stays.
    func testShortSwipeLeavesTabOpen() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        let popup = heading("/popup", in: app)
        XCTAssertTrue(popup.appears(within: Ceiling.load))
        let resting = popup.settledFrame()

        swipeBackFromLeftEdge(to: 0.2, velocity: .slow, in: app)
        XCTAssertFalse(tabsButton(count: 2, in: app).disappears(within: 2), "a short swipe closed the tab")
        // Not `isHittable`: web content near the top of the page reports false even at rest.
        XCTAssertEqual(popup.frame, resting, "the page didn't spring back")
        withExtendedLifetime(server) {}
    }

    /// A tab no link opened (here, typed in the address field) stays put.
    func testSwipeBackLeavesOtherTabsOpen() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        swipeBackFromLeftEdge(in: app)
        XCTAssertFalse(tabsButton(count: 1, in: app).disappears(within: 2), "the tab closed")
        XCTAssertTrue(heading("/", in: app).exists)
        withExtendedLifetime(server) {}
    }

    func testBackButtonClosesLinkOpenedTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/popup", in: app).appears(within: Ceiling.load))

        app.buttons["Page actions"].tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.appears(within: Ceiling.ui), "caret sheet didn't open")
        XCTAssertTrue(back.isEnabled, "Back is disabled on a link-opened tab's first page")
        back.tap()

        XCTAssertTrue(tabsButton(count: 1, in: app).appears(within: Ceiling.ui), "Back didn't close the tab")
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

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

    private func swipeBackFromLeftEdge(to fraction: CGFloat = 0.8, velocity: XCUIGestureVelocity = .fast,
                                       in app: XCUIApplication) {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }
}
