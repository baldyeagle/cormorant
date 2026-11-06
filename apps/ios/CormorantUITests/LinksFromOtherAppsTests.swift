import XCTest

/// Where links from other apps open: in the Space the share extension picked, else the Space a Focus
/// filter names while its Focus is on, else the Space last used, switching there in each case, with a
/// toast that says which (and notes a Focus). Edit Space says when a Focus filter sends links to it.
///
/// The share extension's own sheet and iOS Settings' Focus filter sheet are out of the app's reach, so
/// the app's DEBUG `-uiTesting` hooks stand in for them: `cormorant://ui-testing/share` appends a
/// request naming a Space to the run's own inbox, as the extension does, and drains it;
/// `cormorant://ui-testing/focus` sets or clears the filter's Space, as the system does when a Focus
/// starts or ends. `-uiTestingSpaces` seeds Work (on the Vialumi profile), Projects and Trip beside Home.
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

    /// A shared link with a Space picked opens there, switching to it, and the toast names it; a Space
    /// that no longer exists (here, an unknown name, so no Space at all) opens where links go anyway.
    func testSharedLinkOpensInTheSpacePicked() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)

        share(server.url.appending(path: "shared"), space: "Projects", in: app)
        XCTAssertTrue(heading("/shared", in: app).appears(within: Ceiling.load), "the shared link didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Projects" },
                      "the shared link didn't open in Projects")
        XCTAssertEqual(tabsButton(in: app).label, "Tabs, 2 open", "Projects doesn't have the shared link")
        XCTAssertTrue(toast(in: app).appears(within: Ceiling.ui), "no toast for the shared link")
        XCTAssertTrue(app.staticTexts["Opened in Projects"].exists, "the toast doesn't name Projects")
        XCTAssertFalse(focusNote(in: app).exists, "a Focus note with no Focus filter")
        XCTAssertTrue(toast(in: app).buttons["Move…"].exists, "no Move… for the shared link")

        share(server.url.appending(path: "unpicked"), space: "Gone", in: app)
        XCTAssertTrue(heading("/unpicked", in: app).appears(within: Ceiling.load), "the second link didn't open")
        XCTAssertTrue(waitForToast(2, in: app), "no toast for the second link")
        XCTAssertTrue(app.staticTexts["Opened in Projects"].exists, "it didn't open in the Space last used")
        XCTAssertEqual(tabsButton(in: app).value as? String, "Projects")
        withExtendedLifetime(server) {}
    }

    /// While a Focus filter names Work, links from other apps open there, with "Focus" on the toast; a
    /// Space picked in the share sheet still wins. Once the Focus ends, links open in the Space last used.
    func testFocusFilterSendsLinksToItsSpaceUntilItEnds() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)

        setFocus("Work", in: app)
        openFromAnotherApp(server.url.appending(path: "focused"), in: app)
        XCTAssertTrue(heading("/focused", in: app).appears(within: Ceiling.load), "the link didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Work" },
                      "the link didn't open in the Focus filter's Space")
        XCTAssertTrue(waitForToast(1, in: app), "no toast for the link")
        XCTAssertTrue(app.staticTexts["Opened in Work"].appears(within: Ceiling.ui), "the toast doesn't name Work")
        XCTAssertTrue(focusNote(in: app).exists, "the toast doesn't say a Focus chose Work")

        share(server.url.appending(path: "picked"), space: "Projects", in: app)
        XCTAssertTrue(heading("/picked", in: app).appears(within: Ceiling.load), "the shared link didn't open")
        XCTAssertTrue(waitForToast(2, in: app), "no toast for the shared link")
        XCTAssertTrue(app.staticTexts["Opened in Projects"].appears(within: Ceiling.ui), "the Space picked didn't win")
        // The Focus toast it replaced may still be on its way out.
        XCTAssertTrue(focusNote(in: app).disappears(within: Ceiling.ui), "a Focus note on a link the share sheet placed")

        // The Focus ends: back to the Space last used (Projects, where the last link took you).
        setFocus(nil, in: app)
        openFromAnotherApp(server.url.appending(path: "after"), in: app)
        XCTAssertTrue(heading("/after", in: app).appears(within: Ceiling.load), "the link after the Focus didn't open")
        XCTAssertTrue(waitForToast(3, in: app), "no toast for the link after the Focus")
        XCTAssertEqual(tabsButton(in: app).value as? String, "Projects", "the link didn't open in the Space last used")
        XCTAssertTrue(app.staticTexts["Opened in Projects"].exists, "the toast doesn't name Projects")
        XCTAssertFalse(focusNote(in: app).exists, "a Focus note after the Focus ended")
        withExtendedLifetime(server) {}
    }

    /// The filter's Space is still there after the app is killed and launched again.
    func testFocusFilterSurvivesARelaunch() throws {
        let server = try FixtureServer(html: Self.page)
        let session = "focus-\(UUID().uuidString)"
        let app = launchWithSpaces(server, session: session)
        open(server.url.appending(path: "a"), path: "/a", in: app)
        setFocus("Work", in: app)
        XCTAssertTrue(app.savesSettle(), "the tabs weren't saved")
        app.terminate()

        let next = launchWithSpaces(server, session: session)
        XCTAssertTrue(heading("/a", in: next).appears(within: Ceiling.load), "the relaunch didn't bring back /a")
        let probe = next.descendants(matching: .any)["UITesting.focus"].firstMatch
        XCTAssertTrue(waitUntil(Ceiling.ui) { probe.value as? String == "Work" },
                      "the relaunch lost the Focus filter's Space: \(probe.value as? String ?? "no probe")")
        openFromAnotherApp(server.url.appending(path: "focused"), in: next)
        XCTAssertTrue(heading("/focused", in: next).appears(within: Ceiling.load), "the link didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: next).value as? String == "Work" },
                      "after a relaunch the link didn't open in the Focus filter's Space")
        XCTAssertTrue(focusNote(in: next).exists, "no Focus note after a relaunch")
        withExtendedLifetime(server) {}
    }

    /// Edit Space says when the Focus filter sends links to this Space, and otherwise how to set it up.
    func testEditSpaceShowsTheFocusFilter() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)
        setFocus("Work", in: app)

        openSpaces(in: app)
        app.buttons["Work"].firstMatch.tap()
        let row = app.descendants(matching: .any)["FocusFilterRow"].firstMatch
        XCTAssertTrue(app.textFields["Name"].appears(within: Ceiling.ui), "Edit Space didn't open")
        scrollEditSpace(to: row, in: app)
        XCTAssertTrue(row.appears(within: Ceiling.ui), "Edit Space has no Focus Filter row")
        XCTAssertTrue(row.label.contains("On now: links from other apps open in Work"), row.label)
        let ends = footer(containing: "When the Focus ends", in: app)
        scrollEditSpace(to: ends, in: app)
        XCTAssertTrue(ends.appears(within: Ceiling.ui), "no word on what happens when the Focus ends")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(row.disappears(within: Ceiling.ui), "Edit Space didn't close")

        app.buttons["Projects"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Name"].appears(within: Ceiling.ui), "Projects' Edit Space didn't open")
        scrollEditSpace(to: row, in: app)
        XCTAssertTrue(row.appears(within: Ceiling.ui), "Projects' Edit Space has no Focus Filter row")
        XCTAssertTrue(row.label.contains("Off"), row.label)
        XCTAssertFalse(row.label.contains("On now"), row.label)
        let setUp = footer(containing: "Settings › Focus", in: app)
        scrollEditSpace(to: setUp, in: app)
        XCTAssertTrue(setUp.appears(within: Ceiling.ui), "no word on setting up a Focus filter")
        withExtendedLifetime(server) {}
    }

    /// With only Home nothing new shows: a link the Focus filter or the share sheet sends to Home opens
    /// with no toast, and Edit Space has no Focus group.
    func testOneSpaceShowsNothingNew() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        open(server.url.appending(path: "a"), path: "/a", in: app)

        setFocus("Home", in: app)
        openFromAnotherApp(server.url.appending(path: "focused"), in: app)
        XCTAssertTrue(heading("/focused", in: app).appears(within: Ceiling.load), "the link didn't open")
        share(server.url.appending(path: "shared"), space: "Home", in: app)
        XCTAssertTrue(heading("/shared", in: app).appears(within: Ceiling.load), "the shared link didn't open")
        XCTAssertFalse(toast(in: app).appears(within: 2), "a toast with only Home")
        let toasts = app.descendants(matching: .any)["UITesting.toasts"].firstMatch
        XCTAssertEqual(toasts.value as? String, "0 none", "a toast came and went with only Home")

        openSpaces(in: app)
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Name"].appears(within: Ceiling.ui), "Edit Space didn't open")
        let tabs = app.staticTexts["Tabs"]
        scrollEditSpace(to: tabs, in: app)
        XCTAssertTrue(tabs.exists, "Edit Space's Tabs group isn't on screen")
        XCTAssertFalse(app.descendants(matching: .any)["FocusFilterRow"].exists, "a Focus group with only Home")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launchWithSpaces(_ server: FixtureServer, session: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingSpaces", server.url.absoluteString]
        if let session { app.launchEnvironment["CORMORANT_UI_TESTING_SESSION"] = session }
        app.launch()
        return app
    }

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

    /// As the share extension does with `space` picked: a request naming it, in the inbox.
    private func share(_ url: URL, space: String, in app: XCUIApplication) {
        openInApp("ui-testing", path: "/share", [URLQueryItem(name: "url", value: url.absoluteString),
                                                 URLQueryItem(name: "space", value: space)])
    }

    /// As the system does when a Focus with Cormorant's filter starts (naming `space`) or ends (nil),
    /// then waits until the app has it (`UITesting.focus`).
    private func setFocus(_ space: String?, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) {
        openInApp("ui-testing", path: "/focus", space.map { [URLQueryItem(name: "space", value: $0)] } ?? [])
        let probe = app.descendants(matching: .any)["UITesting.focus"].firstMatch
        XCTAssertTrue(waitUntil(Ceiling.ui) { probe.value as? String == (space ?? "off") },
                      "the Focus filter wasn't set: \(probe.value as? String ?? "no probe")", file: file, line: line)
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

    private func toast(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["Toast"].firstMatch
    }

    /// Waits until the app has put up `count` toasts since launch (`UITesting.toasts`): a new one, not
    /// the last still showing.
    private func waitForToast(_ count: Int, in app: XCUIApplication) -> Bool {
        let probe = app.descendants(matching: .any)["UITesting.toasts"].firstMatch
        return waitUntil(Ceiling.ui) { (probe.value as? String)?.hasPrefix("\(count) ") == true }
    }

    private func focusNote(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Toast.note"].firstMatch
    }

    private func footer(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Swipes Edit Space's form up until `element` is there: the form makes rows only as they come on
    /// screen, and a short screen leaves the Focus group below the fold.
    private func scrollEditSpace(to element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 1...3 where !element.exists {
            form.swipeUp(velocity: .slow)
        }
    }

    /// Settings › Spaces, from the page on screen.
    private func openSpaces(in app: XCUIApplication) {
        app.buttons["Page actions"].tapWhenSettled()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.appears(within: Ceiling.ui), "caret sheet didn't open")
        settings.tap()
        let spaces = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Spaces'")).firstMatch
        XCTAssertTrue(spaces.appears(within: Ceiling.ui), "Settings didn't open")
        spaces.tap()
        XCTAssertTrue(app.navigationBars["Spaces"].appears(within: Ceiling.ui), "Manage Spaces didn't open")
    }
}
