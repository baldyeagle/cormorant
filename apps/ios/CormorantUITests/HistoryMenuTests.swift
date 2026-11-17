import XCTest

/// The caret sheet's Back and Forward: a long-press lists that direction's pages, nearest first, and
/// jumps straight to the one picked; a tap still takes one step.
@MainActor
final class HistoryMenuTests: UITestCase {
    /// Every path serves this page; its title and heading name the path it was loaded at.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
        <h1 id="path">Path</h1>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname
          document.title = 'Page ' + location.pathname
        </script>
        <a href="/two">Go two</a>
        <a href="/three">Go three</a>
        """

    func testLongPressBackAndForwardJumpThroughHistory() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url.appending(path: "one"))
        app.webViews.links["Go two"].tap()
        XCTAssertTrue(heading("/two", in: app).appears(within: Ceiling.load), "link didn't navigate")
        app.webViews.links["Go three"].tap()
        XCTAssertTrue(heading("/three", in: app).appears(within: Ceiling.load), "link didn't navigate")

        // Back two pages at once.
        openCaretSheet(in: app)
        choose("Page /one", fromMenuOf: app.buttons["Back"], offering: ["Page /two"], notOffering: ["Page /three"],
               on: "/three", in: app)
        XCTAssertTrue(heading("/one", in: app).appears(within: Ceiling.load), "didn't jump back to /one")
        XCTAssertTrue(app.buttons["Settings"].disappears(within: Ceiling.ui), "caret sheet stayed up")

        // Forward two pages at once.
        openCaretSheet(in: app)
        choose("Page /three", fromMenuOf: app.buttons["Forward"], offering: ["Page /two"], notOffering: ["Page /one"],
               on: "/one", in: app)
        XCTAssertTrue(heading("/three", in: app).appears(within: Ceiling.load), "didn't jump forward to /three")
        XCTAssertTrue(app.buttons["Settings"].disappears(within: Ceiling.ui), "caret sheet stayed up")

        // A tap is still one step.
        openCaretSheet(in: app)
        app.buttons["Back"].tap()
        XCTAssertTrue(heading("/two", in: app).appears(within: Ceiling.load), "Back didn't step back one page")
        XCTAssertTrue(tabsButton(count: 1, in: app).exists, "Back closed the tab")
        withExtendedLifetime(server) {}
    }

    /// On a tab's first page there's nothing behind Back: a long-press does nothing, as in Safari,
    /// where a tap closes the tab. The tap after the long-press checks the long-press didn't leave Back
    /// ignoring the next tap.
    func testLongPressOnFirstPageBackDoesNothing() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchOnPage(server.url.appending(path: "one"))

        openCaretSheet(in: app)
        let back = app.buttons["Back"]
        back.settledFrame()
        back.press(forDuration: 1.5)
        XCTAssertFalse(app.buttons["Settings"].disappears(within: 2), "a long-press on Back closed the caret sheet")
        XCTAssertTrue(tabsButton(count: 1, in: app).exists, "a long-press on Back closed the tab")
        XCTAssertTrue(heading("/one", in: app).exists, "a long-press on Back left the page")

        back.tap()
        XCTAssertTrue(tabsButton(count: 0, in: app).appears(within: Ceiling.ui), "a tap on Back didn't close the tab")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// Launches with no saved tabs and opens `url` from the launch search panel.
    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(url.path(), in: app).appears(within: Ceiling.load), "fixture page didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        return app
    }

    private func openCaretSheet(in app: XCUIApplication) {
        // The bar slides back in after a page loads; a tap while it moves is dropped.
        app.buttons["Page actions"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Settings"].appears(within: Ceiling.ui), "caret sheet didn't open")
    }

    /// Long-presses `button` for its menu and picks the item whose title is `item`. Now and then a
    /// synthesized long press on the iOS 27.1 simulator highlights a menu's button without opening the
    /// menu (see `SpacesTests.openMenu`), so up to three presses, each first checking the last one
    /// wasn't taken as a tap: that would have stepped off `path` and closed the sheet. A synthesized
    /// tap doesn't activate menu items on the iOS 27 simulator (the menu stays up), so it presses the
    /// item and lifts on it, as a finger can.
    private func choose(_ item: String, fromMenuOf button: XCUIElement, offering: [String], notOffering: [String],
                        on path: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        func choice(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        let target = choice(item)
        var opened = false
        for _ in 1...3 {
            XCTAssertTrue(app.buttons["Settings"].exists && heading(path, in: app).exists,
                          "a long press on \(button.label) was taken as a tap", file: file, line: line)
            button.settledFrame()
            button.press(forDuration: 1)
            if target.appears(within: Ceiling.ui), waitUntil(Ceiling.ui, "Waiting for the menu to settle", { target.isHittable }) {
                opened = true
                break
            }
        }
        XCTAssertTrue(opened, "the \(button.label) menu didn't open", file: file, line: line)
        for title in offering { XCTAssertTrue(choice(title).exists, "the menu doesn't offer \(title)", file: file, line: line) }
        for title in notOffering { XCTAssertFalse(choice(title).exists, "the menu offers \(title)", file: file, line: line) }
        target.settledFrame()
        target.press(forDuration: 0.3, thenDragTo: target)
        XCTAssertTrue(target.disappears(within: Ceiling.ui), "menu didn't close", file: file, line: line)
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    private func tabsButton(count: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["Tabs, \(count) open"]
    }
}
