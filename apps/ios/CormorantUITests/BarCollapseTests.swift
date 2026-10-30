import XCTest

/// Scrolling down shrinks the bar to the host capsule; the page must keep taking touches after that.
@MainActor
final class BarCollapseTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>#y { position: fixed; top: 0; right: 0; background: #ff0; padding: 4px; }</style>
        <p id="y">Scrolled 0</p>
        \(String(repeating: "<p>Filler paragraph.</p>\n", count: 300))
        <script>
          addEventListener("scroll", () => { y.textContent = "Scrolled " + Math.round(scrollY); }, { passive: true });
        </script>
        """

    func testPageScrollsAfterBarCollapses() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        field.typeText(server.url.absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Scrolled 0"].appears(within: Ceiling.load), "fixture page didn't load")

        // One continuous drag that collapses the bar partway through.
        drag(in: app, from: 0.8, to: 0.3)
        let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show toolbar'")).firstMatch
        XCTAssertTrue(capsule.appears(within: Ceiling.ui), "the bar didn't collapse")
        let afterFirst = scrollY(in: app)
        XCTAssertGreaterThan(afterFirst, 0, "the first drag didn't scroll")

        // Then the next ones must scroll too.
        for _ in 0..<2 {
            let before = scrollY(in: app)
            drag(in: app, from: 0.8, to: 0.4)
            XCTAssertTrue(waitUntil(Ceiling.ui) { self.scrollY(in: app) > before }, "the page stopped scrolling after the bar collapsed")
        }
        withExtendedLifetime(server) {}
    }

    private func scrollY(in app: XCUIApplication) -> Int {
        let label = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scrolled '")).firstMatch.label
        return Int(label.dropFirst("Scrolled ".count)) ?? -1
    }

    private func drag(in app: XCUIApplication, from start: CGFloat, to end: CGFloat) {
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
            .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)),
                   withVelocity: .default, thenHoldForDuration: 0.1)
    }
}
