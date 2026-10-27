import XCTest

/// The switcher leaves pages as they were: a tab keeps its scroll position through the switcher and
/// through other tabs being shown, a card opens its own tab and that tab stays, and once it's open the
/// page takes the taps (nothing of the switcher is left over it).
@MainActor
final class TabSwitcherTests: UITestCase {
    /// Every path serves this page. It reports where it's scrolled and the last touch it saw, and has
    /// an in-page link to its very end, so a scroll position is set without a fling.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>#report { position: fixed; top: 120px; right: 0; background: #ff0; padding: 4px; }
        h1, p { margin: 12px 16px; } a { display: inline-block; font-size: 20px; margin: 4px 16px; }</style>
        <h1 id="path">Path</h1>
        <p id="report">Scrolled 0</p>
        <a href="#far">Far down</a>
        \(String(repeating: "<p>Filler paragraph, line after line.</p>\n", count: 300))
        <p id="far">Far paragraph</p>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname;
          document.title = 'Tab ' + location.pathname;
          addEventListener("scroll", () => { report.textContent = "Scrolled " + Math.round(scrollY); }, { passive: true });
          addEventListener("touchend", e => {
            report.textContent = "Touched " + Math.round(e.changedTouches[0].clientY);
          }, { passive: true });
        </script>
        """

    func testSwitcherKeepsScrollPositionAndTheChosenTab() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        // Opening a tab leaves the switcher up, as when its dismiss doesn't take: it must still close,
        // and never come back to take taps meant for the page.
        app.launchArguments = ["-uiTesting", "-uiTestingSkipsFirstSwitcherDismiss"]
        app.launch()
        for path in ["/a", "/b", "/c"] { open(server.url.appending(path: String(path.dropFirst())), path: path, in: app) }

        // To the end of /c.
        app.webViews.links["Far down"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.report(in: app).hasPrefix("Scrolled ") && self.report(in: app) != "Scrolled 0" },
                      "the page didn't scroll down")
        let scrolled = report(in: app)

        // Through the switcher and back: the page hasn't moved.
        openSwitcher(in: app)
        let done = app.buttons["Done"]
        done.tapWhenSettled()
        XCTAssertTrue(done.disappears(within: Ceiling.ui), "the switcher didn't close")
        XCTAssertTrue(heading("/c", in: app).appears(within: Ceiling.ui))
        XCTAssertFalse(waitUntil(2) { self.report(in: app) != scrolled },
                       "the switcher moved the page: \(report(in: app)), was \(scrolled)")

        // A card opens its own tab, which stays.
        openTab("/b", in: app)
        // Past the second after which the switcher used to come back to life when its dismiss hadn't taken.
        XCTAssertFalse(heading("/b", in: app).disappears(within: 3), "another tab replaced the one opened")
        // The page takes taps where the cards were: nothing of the switcher is left over it.
        // Near the top first, where a page's close buttons sit and where the switcher's cards were.
        for point in [CGVector(dx: 0.87, dy: 0.15), CGVector(dx: 0.87, dy: 0.27), CGVector(dx: 0.5, dy: 0.45),
                      CGVector(dx: 0.15, dy: 0.6)] {
            let before = report(in: app)
            // The page's, not the screen's: the iPhone Duo's status bar is a column beside it.
            app.webViews.firstMatch.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(waitUntil(Ceiling.ui) { self.report(in: app) != before && self.report(in: app).hasPrefix("Touched ") },
                          "the page didn't get a tap at \(point)")
            XCTAssertTrue(heading("/b", in: app).exists, "a tap on the page changed the tab")
        }

        // Back to /c: where it was.
        openTab("/c", in: app)
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.report(in: app) == scrolled },
                      "/c came back at \(report(in: app)), not \(scrolled)")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func open(_ url: URL, path: String, in app: XCUIApplication) {
        let field = app.textFields["Search or enter address"]
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "\(path) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
    }

    private func openSwitcher(in app: XCUIApplication) {
        // Scrolled down, the bar is a capsule; tapping it brings the tabs button back.
        let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show toolbar'")).firstMatch
        if capsule.exists { capsule.tapWhenSettled() }
        let tabs = app.buttons["Tabs, 3 open"]
        XCTAssertTrue(tabs.appears(within: Ceiling.ui), "no tabs button")
        tabs.tapWhenSettled()
        XCTAssertTrue(app.buttons["Done"].appears(within: Ceiling.ui), "switcher didn't open")
    }

    /// Opens the switcher and taps the card of the tab at `path`: the one just behind the front card,
    /// whose leading sliver shows.
    private func openTab(_ path: String, in app: XCUIApplication) {
        openSwitcher(in: app)
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'TabCard' AND label == %@", "Tab \(path)")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for \(path)")
        let frame = card.settledFrame()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: max(frame.minX, 0) + 20, dy: frame.midY)).tap()
        XCTAssertTrue(app.buttons["Done"].disappears(within: Ceiling.ui), "the switcher didn't close")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "the card didn't open \(path)")
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    /// What the page last reported: its scroll position or the last touch.
    private func report(in app: XCUIApplication) -> String {
        app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scrolled ' OR label BEGINSWITH 'Touched '")).firstMatch.label
    }
}
