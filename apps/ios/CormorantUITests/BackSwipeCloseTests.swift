import XCTest

/// Arc's back-to-close: swiping in from the left edge on the first page of a tab a link opened
/// closes it and returns to the tab viewed before it. Before that, the swipe is WebKit's back.
@MainActor
final class BackSwipeCloseTests: UITestCase {
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
        \(selectionReport)
        """

    /// Added to `page`: makes it tall enough to scroll, and has it say so once it has.
    private static let scrollReport = """
        <p id="scrolled" style="position: fixed; top: 0; right: 0; margin: 0">Not scrolled</p>
        <div style="height: 4000px"></div>
        <script>
          addEventListener('scroll', () => { if (scrollY > 0) document.getElementById('scrolled').textContent = 'Scrolled' }, { passive: true })
        </script>
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
        let item = app.buttons["Open in New Tab"]
        XCTAssertTrue(pressForLinkMenu(link, until: item, in: app), "no link menu")
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
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab; \(server.requestLog)")
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
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab; \(server.requestLog)")
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
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab; \(server.requestLog)")
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
        // The web view's frame, not the heading's: the swipe moves the web view with a transform,
        // which UIKit reports as it is, while WebKit's frames for the page's own elements can lag it.
        let page = app.webViews.containing(NSPredicate(format: "label == %@", "Path /popup")).firstMatch
        let resting = page.settledFrame()

        swipeBackFromLeftEdge(to: 0.2, velocity: .slow, in: app)
        XCTAssertFalse(tabsButton(count: 2, in: app).disappears(within: 2), "a short swipe closed the tab")
        XCTAssertTrue(waitUntil(Ceiling.ui) { page.frame == resting },
                      "the page didn't spring back: \(page.frame), at rest \(resting)")
        withExtendedLifetime(server) {}
    }

    /// On its side the page stops short of the screen's edges (the safe area beside it), so the
    /// swipe starts beside the page, not on it.
    func testSwipeBackFromScreenEdgeClosesTabInLandscape() throws {
        try XCTSkipIf(Self.simulatorStaysUpright, "this simulator doesn't turn on its side")
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url)

        app.webViews.links["Blank target"].tap()
        XCTAssertTrue(tabsButton(count: 2, in: app).appears(within: Ceiling.ui), "no new tab")
        XCTAssertTrue(heading("/popup", in: app).appears(within: Ceiling.load))

        rotateToLandscape(app)
        try XCTSkipUnless(app.webViews.firstMatch.settledFrame().minX > 8, "no safe area at the left edge on its side")
        swipeBackFromLeftEdge(in: app)
        XCTAssertTrue(tabsButton(count: 1, in: app).appears(within: Ceiling.ui), "swipe didn't close the tab")
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab; \(server.requestLog)")
        withExtendedLifetime(server) {}
    }

    /// WebKit's back and forward swipes start beside the page too, but they are the web view's own,
    /// and get a touch only if it lands in the web view: the app hands it the ones beside the page.
    /// Synthesized drags don't drive those swipes (see above), so this checks the hand-off with a
    /// drag the page's scroll view takes.
    func testDragBesidePageScrollsIt() throws {
        let server = try FixtureServer(html: Self.page + Self.scrollReport)
        let app = launchOnPage(server.url)

        if gutter(in: app) == nil {
            try XCTSkipIf(Self.simulatorStaysUpright, "nothing beside the page, and this simulator doesn't turn on its side")
            rotateToLandscape(app)
        }
        let x = try XCTUnwrap(gutter(in: app), "nothing beside the page on its side either")
        // The keyboard the address was typed on would take the drag while it's still going.
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard was still up")
        let height = app.frame.height
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x, dy: height * 0.75))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: height * 0.4)))
        XCTAssertTrue(app.webViews.staticTexts["Scrolled"].appears(within: Ceiling.ui), "a drag beside the page didn't scroll it")
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
        XCTAssertTrue(heading("/", in: app).appears(within: Ceiling.load), "didn't return to the previous tab; \(server.requestLog)")
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

    /// CI's iPhone Duo, which `XCUIDevice` can't turn: asked first, so no test waits to see that it hasn't.
    private static let simulatorStaysUpright = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"

    /// Turns the simulator on its side until the test ends, and waits for the app to follow, both ways.
    private func rotateToLandscape(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let upright = app.frame.size
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
            _ = waitUntil(Ceiling.ui, "Waiting for the app to turn back") { app.frame.size == upright }
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(Ceiling.ui, "Waiting for the app to rotate") { app.frame.size != upright },
                      "the app didn't turn on its side", file: file, line: line)
    }

    /// The middle, in points across the screen, of the strip beside the page: the status-bar column on
    /// CI's iPhone Duo, the safe area on a phone on its side. Nil where the page fills the width.
    private func gutter(in app: XCUIApplication) -> CGFloat? {
        let web = app.webViews.firstMatch.settledFrame(), window = app.frame
        if window.maxX - web.maxX >= 8 { return (web.maxX + window.maxX) / 2 }
        if web.minX - window.minX >= 8 { return (window.minX + web.minX) / 2 }
        return nil
    }

    /// Once the app reports every tab done loading (`savesSettle`): whether the swipe closes the tab
    /// depends on the tab's back history, which a navigation still under way may not have settled (on
    /// a loaded CI runner, a swipe made as soon as a slow Back's page showed didn't close the tab).
    private func swipeBackFromLeftEdge(to fraction: CGFloat = 0.8, velocity: XCUIGestureVelocity = .fast,
                                       in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.savesSettle(), "the page was still loading", file: file, line: line)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }
}
