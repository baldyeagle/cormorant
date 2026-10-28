import XCTest

/// Arc's back-to-close: swiping in from the left edge on the first page of a tab a link opened
/// closes it and returns to the tab viewed before it. Before that, the swipe is WebKit's back.
@MainActor
final class BackSwipeCloseTests: XCTestCase {
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
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.press(forDuration: 1.5)
        let item = app.buttons["Open in New Tab"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no link menu")
        let settled = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: item)
        wait(for: [settled], timeout: 5)
        item.tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).waitForExistence(timeout: 5), "no new tab")
        XCTAssertTrue(heading("/next", in: app).waitForExistence(timeout: 10))

        app.webViews.links["Third page"].tap()
        XCTAssertTrue(heading("/third", in: app).waitForExistence(timeout: 10), "link didn't navigate")

        swipeBackFromLeftEdge(in: app)
        XCTAssertFalse(tabsButton(count: 2, in: app).waitForNonExistence(timeout: 2), "closed a tab that can go back")

        app.buttons["Page actions"].tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "caret sheet didn't open")
        back.tap()
        XCTAssertTrue(heading("/next", in: app).waitForExistence(timeout: 10), "Back didn't go back")
        XCTAssertTrue(tabsButton(count: 2, in: app).exists, "Back closed the tab instead of going back")

        swipeBackFromLeftEdge(in: app)
        XCTAssertTrue(tabsButton(count: 1, in: app).waitForExistence(timeout: 5), "swipe didn't close the tab")
        XCTAssertTrue(heading("/", in: app).waitForExistence(timeout: 10), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    func testSwipeBackClosesBlankTargetTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).waitForExistence(timeout: 5), "no new tab")
        XCTAssertTrue(heading("/popup", in: app).waitForExistence(timeout: 10))

        swipeBackFromLeftEdge(in: app)
        XCTAssertTrue(tabsButton(count: 1, in: app).waitForExistence(timeout: 5), "swipe didn't close the tab")
        XCTAssertTrue(heading("/", in: app).waitForExistence(timeout: 10), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    /// Let go early and the page springs back; the tab stays.
    func testShortSwipeLeavesTabOpen() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).waitForExistence(timeout: 5), "no new tab")
        let popup = heading("/popup", in: app)
        XCTAssertTrue(popup.waitForExistence(timeout: 10))
        let resting = popup.frame

        swipeBackFromLeftEdge(to: 0.2, velocity: .slow, in: app)
        XCTAssertFalse(tabsButton(count: 2, in: app).waitForNonExistence(timeout: 2), "a short swipe closed the tab")
        // Not `isHittable`: web content near the top of the page reports false even at rest.
        XCTAssertEqual(popup.frame, resting, "the page didn't spring back")
        withExtendedLifetime(server) {}
    }

    /// A tab no link opened (here, typed in the address field) stays put.
    func testSwipeBackLeavesOtherTabsOpen() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        swipeBackFromLeftEdge(in: app)
        XCTAssertFalse(tabsButton(count: 1, in: app).waitForNonExistence(timeout: 2), "the tab closed")
        XCTAssertTrue(heading("/", in: app).exists)
        withExtendedLifetime(server) {}
    }

    func testBackButtonClosesLinkOpenedTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).waitForExistence(timeout: 5), "no new tab")
        XCTAssertTrue(heading("/popup", in: app).waitForExistence(timeout: 10))

        app.buttons["Page actions"].tap()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "caret sheet didn't open")
        XCTAssertTrue(back.isEnabled, "Back is disabled on a link-opened tab's first page")
        back.tap()

        XCTAssertTrue(tabsButton(count: 1, in: app).waitForExistence(timeout: 5), "Back didn't close the tab")
        XCTAssertTrue(heading("/", in: app).waitForExistence(timeout: 10), "didn't return to the previous tab")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        // See LinkContextMenuTests: a context menu never reports its animations idle on this simulator.
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

    private func swipeBackFromLeftEdge(to fraction: CGFloat = 0.8, velocity: XCUIGestureVelocity = .fast,
                                       in app: XCUIApplication) {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }
}
