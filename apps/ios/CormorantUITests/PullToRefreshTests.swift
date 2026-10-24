import XCTest

/// Pulling down from the top of a page reloads it; the same pull anywhere else scrolls.
/// Each fixture counts its loads in `sessionStorage`, which survives a reload of the tab, and counts
/// touch moves, so a test that expects no reload can tell the drag reached the page.
@MainActor
final class PullToRefreshTests: XCTestCase {
    private static func page(style: String = "", body: String) -> String {
        """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>\(style)</style>
        <script>
          const loads = Number(sessionStorage.loads || 0) + 1;
          sessionStorage.loads = loads;
          let moves = 0;
          addEventListener("DOMContentLoaded", () => {
            document.getElementById("count").textContent = "Load " + loads;
          });
          // Passive, so the page doesn't make WebKit wait on it before scrolling.
          addEventListener("touchmove", () => {
            document.getElementById("moves").textContent = "Touch moves: " + ++moves;
          }, { passive: true });
        </script>
        <h1 id="count">Loading</h1>
        <p id="moves">Touch moves: 0</p>
        \(body)
        """
    }

    private static let filler = String(repeating: "<p>Filler paragraph.</p>\n", count: 150)

    func testPullAtTopReloadsAndSettles() throws {
        let server = try FixtureServer(html: Self.page(body: Self.filler))
        let app = launchOnPage(server.url)
        let heading = app.webViews.staticTexts["Load 1"]
        let restingTop = heading.frame.minY

        pull(in: app)

        let reloaded = app.webViews.staticTexts["Load 2"]
        // Right after a fresh install the simulator can drop a synthesized drag entirely (the touch
        // begins and ends without moving). Only then, try once more.
        if !reloaded.waitForExistence(timeout: 8), heading.exists, touchMoves(in: app) == 0 {
            pull(in: app)
        }
        XCTAssertTrue(reloaded.waitForExistence(timeout: 15), "pulling at the top didn't reload")
        // The spinner holds the page down by its own height until it ends.
        assertSettles(reloaded, at: restingTop, "the page didn't settle after the reload")
        // WebKit can put the page back at the top on reload whether or not the spinner is still
        // there; a small tug that bounces back shows where the page rests now. A spinner that never
        // ended would hold it its own height lower.
        drag(in: app, from: 0.3, to: 0.36)
        assertSettles(reloaded, at: restingTop, "the spinner didn't end")
        XCTAssertFalse(app.webViews.staticTexts["Load 3"].waitForExistence(timeout: 2), "the tug reloaded")
        XCTAssertTrue(app.buttons["Page actions"].isHittable, "the bar didn't stay expanded")
        withExtendedLifetime(server) {}
    }

    func testPullWhileScrolledDownDoesNotReload() throws {
        // Far further down than the pull's travel, so the pull can't reach the top.
        let body = Self.filler + "<script>addEventListener('load', () => scrollTo(0, 2000));</script>"
        let server = try FixtureServer(html: Self.page(body: body))
        let app = launchOnPage(server.url)
        let heading = app.webViews.staticTexts["Load 1"]
        let scrolled = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: heading)
        wait(for: [scrolled], timeout: 5)
        let moves = touchMoves(in: app)

        pull(in: app)

        assertDragReachedPage(in: app, after: moves)
        XCTAssertFalse(app.webViews.staticTexts["Load 2"].waitForExistence(timeout: 4), "a pull mid-page reloaded")
        withExtendedLifetime(server) {}
    }

    /// A page that scrolls in its own element: pulling inside it scrolls the element. The page
    /// itself fits the screen and sits at its top, so only the element's scroll keeps it from reloading.
    func testPullInsideScrollingElementScrollsIt() throws {
        let style = "body { margin: 0; } #scroller { height: 60vh; overflow-y: auto; }"
        let body = """
            <p id="position">Scroller at 0</p>
            <div id="scroller">\(Self.filler)</div>
            <script>
              scroller.addEventListener("scroll", () => {
                position.textContent = "Scroller at " + Math.round(scroller.scrollTop);
              });
              addEventListener("load", () => { scroller.scrollTop = 1200; });
            </script>
            """
        let server = try FixtureServer(html: Self.page(style: style, body: body))
        let app = launchOnPage(server.url)
        let start = app.webViews.staticTexts["Scroller at 1200"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "the scroller didn't start mid-way")

        // Within the scroller, and shorter than its 1200pt of travel back to its top.
        drag(in: app, from: 0.35, to: 0.75)

        XCTAssertTrue(start.waitForNonExistence(timeout: 3), "the pull didn't scroll the element")
        XCTAssertFalse(app.webViews.staticTexts["Load 2"].waitForExistence(timeout: 4),
                       "a pull inside a scrolled element reloaded")

        // The page itself can still be pulled, from outside the element; otherwise the above proves nothing.
        let heading = app.webViews.staticTexts["Load 1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        heading.press(forDuration: 0.05, thenDragTo: heading.withOffset(CGVector(dx: 0, dy: 300)),
                      withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.webViews.staticTexts["Load 2"].waitForExistence(timeout: 15),
                      "the page couldn't be pulled from outside the element")
        withExtendedLifetime(server) {}
    }

    /// `overscroll-behavior: none` on the root is a page saying it handles overscroll itself.
    func testPullOnPageThatDisablesOverscrollDoesNotReload() throws {
        let server = try FixtureServer(html: Self.page(style: "html { overscroll-behavior: none; }",
                                                       body: Self.filler))
        let app = launchOnPage(server.url)

        pull(in: app)

        assertDragReachedPage(in: app)
        XCTAssertFalse(app.webViews.staticTexts["Load 2"].waitForExistence(timeout: 4),
                       "a page with overscroll-behavior: none reloaded")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// The fixture's count of `touchmove` events so far.
    private func touchMoves(in app: XCUIApplication) -> Int {
        let label = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Touch moves: '"))
            .firstMatch.label
        return Int(label.dropFirst("Touch moves: ".count)) ?? 0
    }

    /// Without this, a dropped drag would pass every "doesn't reload" test.
    private func assertDragReachedPage(in app: XCUIApplication, after moves: Int = 0,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let counted = expectation(for: NSPredicate { _, _ in self.touchMoves(in: app) > moves }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 3), .completed,
                       "the drag never reached the page", file: file, line: line)
    }

    private func assertSettles(_ element: XCUIElement, at minY: CGFloat, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let settled = expectation(for: NSPredicate { _, _ in abs(element.frame.minY - minY) < 2 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed, message, file: file, line: line)
    }

    /// A slow drag from near the top of the page to past the middle, held, then released.
    private func pull(in app: XCUIApplication) {
        drag(in: app, from: 0.2, to: 0.65)
    }

    /// A slow vertical drag between two heights of the web view (0 is its top), held, then released.
    private func drag(in app: XCUIApplication, from start: CGFloat, to end: CGFloat) {
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
            .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Launches with no saved tabs and opens `url` from the launch search panel.
    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search panel at launch")
        field.typeText(url.absoluteString + "\n")

        // Generous: a fresh simulator is also downloading and compiling the filter lists meanwhile.
        XCTAssertTrue(app.webViews.staticTexts["Load 1"].waitForExistence(timeout: 30), "fixture page didn't load")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "search panel didn't close on submit")
        return app
    }
}
