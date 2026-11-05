import XCTest

/// Switching Spaces: from the tabs button's long-press menu, the switcher's Space strip and its title
/// menu, each landing on the tab last viewed in the Space, or the search panel in an empty one.
/// `-uiTestingSpaces` seeds Work (on a profile of its own) and Projects, with one fixture tab each, and
/// an empty Trip, beside an empty Home. With only Home, all that shows is a Spaces button in the
/// switcher, to Manage Spaces.
@MainActor
final class SpacesTests: UITestCase {
    /// Every path serves this page, which names its path.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <p>Spaces fixture.</p>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname;
          document.title = 'Tab ' + location.pathname;
        </script>
        """

    func testLongPressMenuListsSpacesAndSwitches() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "home"), path: "/home", in: app)

        let tabs = tabsButton(in: app)
        // Each Space with its tab count; the profile only where it isn't the default.
        let home = menuItem("Home", in: app), work = menuItem("Work", in: app), projects = menuItem("Projects", in: app)
        XCTAssertTrue(openMenu(tabs, by: .longPress, until: work), "the long-press menu has no Spaces")
        XCTAssertTrue(home.exists && projects.exists, "a Space is missing from the menu")
        XCTAssertTrue(describe(home).contains("1 tab") && !describe(home).contains("profile"), describe(home))
        XCTAssertTrue(describe(work).contains("1 tab · Vialumi profile"), describe(work))
        XCTAssertFalse(describe(projects).contains("profile"), describe(projects))
        // The items it had before stay.
        XCTAssertTrue(app.buttons["Search Tabs"].exists, "Search Tabs left the menu")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'New Tab' AND identifier != 'NewTabPill'")).firstMatch.exists,
                      "New Tab left the menu")

        let page = heading("/home", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        page.tap()
        XCTAssertTrue(work.disappears(within: Ceiling.ui), "the menu didn't close")
        choose(work, from: tabs, by: .longPress, closingAt: page, until: { tabs.value as? String == "Work" }, in: app)
        XCTAssertTrue(heading("/work", in: app).appears(within: Ceiling.load), "switching to Work didn't show its tab")
        withExtendedLifetime(server) {}
    }

    func testSwitcherStripAndTitleMenuSwitchSpaces() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "home"), path: "/home", in: app)

        openSwitcher(in: app)
        let title = app.buttons["SpaceTitleMenu"]
        XCTAssertTrue(title.appears(within: Ceiling.ui), "no Space title in the switcher")
        XCTAssertEqual(title.label, "Space, Home")
        let strip = app.buttons.matching(identifier: "SpaceStrip")
        XCTAssertEqual(strip.count, 4, "the strip doesn't have every Space")
        XCTAssertTrue(strip["Home"].isSelected, "Home isn't marked active in the strip")
        XCTAssertFalse(app.buttons["ManageSpacesButton"].exists, "the one-Space Spaces button shows beside the strip")

        // The strip switches the cards to Projects'; the switcher stays up.
        strip["Projects"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Projects" }, "the strip didn't switch to Projects")
        XCTAssertTrue(strip["Projects"].isSelected && !strip["Home"].isSelected, "the strip doesn't mark Projects")
        XCTAssertTrue(app.buttons["Done"].exists, "switching Spaces closed the switcher")

        // The title menu lists the same Spaces and switches too.
        let work = menuItem("Work", in: app)
        XCTAssertTrue(openMenu(title, by: .tap, until: work), "the title menu has no Spaces")
        XCTAssertTrue(describe(work).contains("Vialumi profile"), describe(work))
        let titleCenter = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        titleCenter.tap()
        XCTAssertTrue(work.disappears(within: Ceiling.ui), "the menu didn't close")
        choose(work, from: title, by: .tap, closingAt: titleCenter, until: { title.label == "Space, Work" }, in: app)

        app.buttons["Done"].tap()
        XCTAssertTrue(heading("/work", in: app).appears(within: Ceiling.load), "Done didn't show Work's tab")
        withExtendedLifetime(server) {}
    }

    /// Back in a Space, its last viewed tab shows, not its newest.
    func testSwitchingBackReturnsToTheTabLeft() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)
        open(server.url.appending(path: "b"), path: "/b", in: app)

        // Back to /a, the older tab, from its card.
        openSwitcher(in: app)
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'TabCard' AND label == 'Tab /a'")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for /a")
        let frame = card.settledFrame()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: max(frame.minX, 0) + 20, dy: frame.midY)).tap()
        XCTAssertTrue(app.buttons["Done"].disappears(within: Ceiling.ui), "the switcher didn't close")
        XCTAssertTrue(heading("/a", in: app).appears(within: Ceiling.load), "the card didn't open /a")

        // To Projects and back, through the strip.
        openSwitcher(in: app)
        let strip = app.buttons.matching(identifier: "SpaceStrip")
        strip["Projects"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { strip["Projects"].isSelected }, "the strip didn't switch to Projects")
        app.buttons["Done"].tap()
        XCTAssertTrue(heading("/projects", in: app).appears(within: Ceiling.load), "Projects' tab didn't show")

        openSwitcher(in: app)
        strip["Home"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { strip["Home"].isSelected }, "the strip didn't switch to Home")
        app.buttons["Done"].tap()
        XCTAssertTrue(heading("/a", in: app).appears(within: Ceiling.load), "Home came back on another tab than /a")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).label == "Tabs, 2 open" }, "Home's tabs changed")
        withExtendedLifetime(server) {}
    }

    /// An empty Space shows the search panel, however it's reached: from the menu out of another empty
    /// Space or out of a page, and from the switcher.
    func testAnEmptySpaceShowsTheSearchPanel() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        app.buttons["Close search"].firstMatch.tap()
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "the search panel didn't close")

        // Empty Home to empty Trip. The menu closes with a tap above it, on the empty state.
        let tabs = tabsButton(in: app)
        XCTAssertTrue(tabs.appears(within: Ceiling.ui), "no tabs button")
        choose(menuItem("Trip", in: app), from: tabs, by: .longPress,
               closingAt: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)), until: { self.isIn("Trip", in: app) }, in: app)
        assertSearchPanelStaysUp(in: app)

        // A page in Trip, then to empty Home.
        field.typeText(server.url.appending(path: "trip").absoluteString + "\n")
        XCTAssertTrue(heading("/trip", in: app).appears(within: Ceiling.load), "/trip didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        choose(menuItem("Home", in: app), from: tabs, by: .longPress,
               closingAt: heading("/trip", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), until: { self.isIn("Home", in: app) }, in: app)
        assertSearchPanelStaysUp(in: app)

        // Back to Trip's page, then to empty Home from the switcher.
        app.buttons["Close search"].firstMatch.tap()
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "the search panel didn't close")
        openSwitcher(in: app)
        let strip = app.buttons.matching(identifier: "SpaceStrip")
        strip["Trip"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { strip["Trip"].isSelected }, "the strip didn't switch to Trip")
        app.buttons["Done"].tap()
        XCTAssertTrue(heading("/trip", in: app).appears(within: Ceiling.load), "Trip's tab didn't show")
        openSwitcher(in: app)
        strip["Home"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { strip["Home"].isSelected }, "the strip didn't switch to Home")
        XCTAssertTrue(app.staticTexts["No Open Tabs"].appears(within: Ceiling.ui), "Home's empty switcher says nothing")
        app.buttons["Done"].tap()
        assertSearchPanelStaysUp(in: app)
        withExtendedLifetime(server) {}
    }

    /// With only Home, which is everyone until a second Space is made, nothing of Spaces shows.
    func testOneSpaceShowsOnlyTheSpacesButton() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        open(server.url.appending(path: "home"), path: "/home", in: app)

        let searchTabs = app.buttons["Search Tabs"]
        XCTAssertTrue(openMenu(tabsButton(in: app), by: .longPress, until: searchTabs), "long-press didn't open the menu")
        XCTAssertFalse(menuItem("Home", in: app).exists, "the menu lists Spaces with only Home")
        app.webViews.staticTexts["Path /home"].tap()
        XCTAssertTrue(searchTabs.disappears(within: Ceiling.ui), "menu didn't close")

        openSwitcher(in: app)
        XCTAssertTrue(app.navigationBars.staticTexts["1 Tab"].exists, "the switcher's title isn't the tab count")
        XCTAssertFalse(app.buttons["SpaceTitleMenu"].exists, "the switcher has a Space title with only Home")
        XCTAssertFalse(app.buttons.matching(identifier: "SpaceStrip").firstMatch.exists, "the switcher has a Space strip with only Home")

        // Its one sign of Spaces: a button to Manage Spaces, in the strip's place.
        let spaces = app.buttons["ManageSpacesButton"]
        XCTAssertTrue(spaces.appears(within: Ceiling.ui), "no Spaces button with only Home")
        spaces.tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Spaces"].appears(within: Ceiling.ui), "Manage Spaces didn't open")
        XCTAssertTrue(app.navigationBars.staticTexts["1 Tab"].disappears(within: Ceiling.ui), "the switcher is still up")
        withExtendedLifetime(server) {}
    }

    func testTabsMenuOpensManageSpaces() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "home"), path: "/home", in: app)

        let tabs = tabsButton(in: app)
        let page = heading("/home", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        choose(menuItem("Manage Spaces", in: app), from: tabs, by: .longPress, closingAt: page,
               until: { app.navigationBars["Spaces"].exists }, in: app)
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launchWithSpaces(_ server: FixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingSpaces", server.url.absoluteString]
        app.launch()
        return app
    }

    private func tabsButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch
    }

    /// A Space's row in a Space menu (not the strip's glyph, which is labeled with the name alone).
    private func menuItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != 'SpaceStrip'", name)).firstMatch
    }

    /// The panel is up, stays up, and has the keyboard (losing focus closes it).
    private func assertSearchPanelStaysUp(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.ui), "the empty Space didn't bring up the search panel", file: file, line: line)
        XCTAssertFalse(field.disappears(within: 2), "the search panel closed by itself", file: file, line: line)
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "search field lost focus", file: file, line: line)
    }

    /// Whether the app is in the Space: the tabs button says so, or the search panel is up (it hides the
    /// bar), having just been switched to an empty one.
    private func isIn(_ space: String, in app: XCUIApplication) -> Bool {
        app.textFields["Search or enter address"].exists
            || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, ' AND value == %@", space)).firstMatch.exists
    }

    private func describe(_ element: XCUIElement) -> String {
        [element.label, element.value as? String].compactMap { $0 }.joined(separator: " | ")
    }

    /// How a menu opens: the tabs button's on a long press, the switcher title's on a tap.
    private enum MenuOpening { case longPress, tap }

    /// Opens `button`'s menu until `item` is up and has stopped moving; false if it never is. Now and
    /// then a synthesized long press on the iOS 27.1 simulator highlights the tabs button without
    /// opening its menu (by hand it always opens), so up to three tries, each given the full ceiling.
    private func openMenu(_ button: XCUIElement, by opening: MenuOpening, until item: XCUIElement) -> Bool {
        for _ in 1...3 {
            switch opening {
            case .longPress: button.press(forDuration: 1)
            case .tap: button.tap()
            }
            if item.appears(within: Ceiling.ui), waitUntil(Ceiling.ui, "Waiting for the menu to settle", { item.isHittable }) {
                item.settledFrame()
                return true
            }
        }
        return false
    }

    /// Chooses `item` from `button`'s menu until `chosen` holds. A synthesized tap doesn't activate
    /// SwiftUI menu items on the iOS 27 simulator, so do what a finger also can: open the menu to see
    /// where the item sits, close it (tapping at `close`, outside it), then hold the button and slide
    /// onto the item. That press can fail to open the menu too (see `openMenu`): up to three tries.
    private func choose(_ item: XCUIElement, from button: XCUIElement, by opening: MenuOpening,
                        closingAt close: XCUICoordinate, until chosen: () -> Bool, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 1...3 {
            XCTAssertTrue(openMenu(button, by: opening, until: item), "the menu didn't open", file: file, line: line)
            let frame = item.frame
            close.tap()
            XCTAssertTrue(item.disappears(within: Ceiling.ui), "the menu didn't close", file: file, line: line)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.2, thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)))
            if waitUntil(Ceiling.ui, "Waiting for \(item.description) to be chosen", chosen) { return }
            // Opened but missed the item: close the menu before trying again.
            if item.exists {
                close.tap()
                XCTAssertTrue(item.disappears(within: Ceiling.ui), "the menu didn't close", file: file, line: line)
            }
        }
        XCTFail("couldn't choose \(item.description)", file: file, line: line)
    }

    private func open(_ url: URL, path: String, in app: XCUIApplication) {
        let field = app.textFields["Search or enter address"]
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "\(path) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
    }

    private func openSwitcher(in app: XCUIApplication) {
        let tabs = tabsButton(in: app)
        XCTAssertTrue(tabs.appears(within: Ceiling.ui), "no tabs button")
        tabs.tapWhenSettled()
        XCTAssertTrue(app.buttons["Done"].appears(within: Ceiling.ui), "switcher didn't open")
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }
}
