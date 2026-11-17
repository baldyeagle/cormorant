import XCTest

/// A link from another app opens full screen on its page, wherever the app was left. Where it opens
/// (the Space picked in the share extension, a Focus filter's, the Space last used), its toast, and
/// Edit Space's Focus group are checked in-process (CormorantTests' LinksFromOtherAppsTests).
@MainActor
final class LinksFromOtherAppsTests: UITestCase {
    /// Every path serves this page, which names its path.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname;
          document.title = 'Tab ' + location.pathname;
        </script>
        """

    /// A link from another app opens full screen on its page, not under a switcher left up when the app
    /// was last used (where the new tab showed only as a card).
    func testLinkFromAnotherAppClosesTheSwitcher() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        open(server.url.appending(path: "a"), path: "/a", in: app)
        tabsButton(in: app).tapWhenSettled()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.appears(within: Ceiling.ui), "switcher didn't open")

        // Away to another app, and back by a link from it.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: Ceiling.ui), "Settings didn't come up")
        openFromAnotherApp(server.url.appending(path: "linked"), in: app)
        // A query on an app still in the background finds nothing, which would pass the check below.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Ceiling.ui), "the link didn't bring the app back")

        XCTAssertTrue(done.disappears(within: Ceiling.ui), "the switcher stayed up over the link's page")
        XCTAssertTrue(heading("/linked", in: app).appears(within: Ceiling.load), "the link's page isn't showing")
        XCTAssertFalse(done.exists, "the switcher came back over the link's page")
        XCTAssertEqual(tabsButton(in: app).label, "Tabs, 2 open", "the link didn't open in a new tab")
        XCTAssertTrue(tabsButton(in: app).isHittable, "the bar isn't on screen")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func open(_ url: URL, path: String, in app: XCUIApplication) {
        let field = searchField(in: app)
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "\(path) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        // The keyboard takes taps meant for the bar until it has gone.
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard stayed up")
    }

    /// As the system hands the app a link another app opened, with Cormorant the default browser.
    private func openFromAnotherApp(_ url: URL, in app: XCUIApplication) {
        openInApp("open", [URLQueryItem(name: "url", value: url.absoluteString)])
    }

    /// Through the system: `XCUIApplication.open(_:)` relaunches the app, losing its tabs.
    private func openInApp(_ host: String, path: String = "", _ query: [URLQueryItem]) {
        var components = URLComponents()
        components.scheme = "cormorant"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        XCUIDevice.shared.system.open(components.url!)
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    private func tabsButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch
    }
}
