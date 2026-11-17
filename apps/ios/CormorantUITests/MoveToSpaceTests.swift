import XCTest

/// Moving a tab to another Space from the screen: a switcher card's long-press menu, and the toast's
/// buttons over the search panel. `-uiTestingSpaces` seeds Work (on the Vialumi profile, so moving
/// there reloads) and Projects with one tab each, and an empty Trip, beside Home. The moves, Open in
/// Space, the toasts' text and buttons, and how it all is with only Home are checked in-process
/// (CormorantTests' MoveToSpaceTests).
@MainActor
final class MoveToSpaceTests: UITestCase {
    /// Every path serves this page, which names its path and links to /next.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
        <h1 id="path">Path</h1>
        <a href="/next">Next page</a>
        <script>
          document.getElementById('path').textContent = 'Path ' + location.pathname;
          document.title = 'Tab ' + location.pathname;
        </script>
        \(selectionReport)
        """

    /// From the card's menu: the switcher goes with the card to Work, the toast's Undo brings both back
    /// to Home, and its Back to Home leaves the card where it went.
    func testMoveFromCardMenuThenUndoAndBack() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)
        open(server.url.appending(path: "b"), path: "/b", in: app)

        openSwitcher(in: app)
        openCardMenu(on: "Tab /a", in: app)
        let work = submenuItem("Work", in: app)
        XCTAssertTrue(work.appears(within: Ceiling.ui), "no Work in Move to Space")
        // The tab's own Space is listed, but can't be chosen; Work's profile isn't Home's.
        XCTAssertTrue(describe(submenuItem("Home", in: app)).contains("Here now"), describe(submenuItem("Home", in: app)))
        XCTAssertFalse(submenuItem("Home", in: app).isEnabled, "the tab's own Space can be chosen")
        XCTAssertTrue(describe(work).contains("Vialumi profile · Reloads"), describe(work))
        XCTAssertFalse(describe(submenuItem("Projects", in: app)).contains("Reloads"), describe(submenuItem("Projects", in: app)))
        XCTAssertFalse(app.buttons["New Space"].exists, "New Space is in the move menu")
        chooseInMenu(work, in: app)

        let toast = self.toast(in: app)
        let title = app.buttons["SpaceTitleMenu"]
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the move")
        XCTAssertTrue(app.staticTexts["Moved to Work"].exists, "the toast doesn't say where the tab went")
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Work" }, "the switcher didn't go to Work")
        XCTAssertTrue(card("Tab /a", in: app).appears(within: Ceiling.ui), "the moved card isn't in Work")
        XCTAssertFalse(toast.buttons["Show"].exists, "the toast still offers Show")

        // Undo: back in Home, the card with it.
        toast.buttons["Undo"].tapWhenSettled()
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Home" }, "Undo didn't go back to Home")
        XCTAssertTrue(card("Tab /a", in: app).appears(within: Ceiling.ui), "Undo didn't bring the card back")
        XCTAssertTrue(card("Tab /b", in: app).exists, "Home lost its other card")
        XCTAssertTrue(toast.disappears(within: Ceiling.ui), "the toast stayed after Undo")

        // Again to Projects, then Back to Home: the card stays in Projects.
        openCardMenu(on: "Tab /a", in: app)
        chooseInMenu(submenuItem("Projects", in: app), in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the second move")
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Projects" }, "the switcher didn't go to Projects")
        toast.buttons["Back to Home"].tapWhenSettled()
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Home" }, "Back didn't go to Home")
        XCTAssertTrue(card("Tab /b", in: app).appears(within: Ceiling.ui), "Home's other card isn't there")
        XCTAssertFalse(card("Tab /a", in: app).exists, "the moved card came back with Back")
        app.buttons["Done"].tapWhenSettled()
        XCTAssertTrue(heading("/b", in: app).appears(within: Ceiling.load), "Home didn't show its tab")
        withExtendedLifetime(server) {}
    }

    /// The toast stays above the search panel, out of the field's way, when a new tab is begun after a
    /// move; its Undo takes the page back to Home and closes the panel, as switching tabs does.
    func testUndoOverTheSearchPanelClosesIt() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)
        open(server.url.appending(path: "b"), path: "/b", in: app)

        openMoveSheet(in: app)
        destination("Projects", in: app).tapWhenSettled()
        let toast = self.toast(in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the move")
        app.buttons["NewTabPill"].tapWhenSettled()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.ui), "New Tab didn't bring up the search panel")
        let undo = toast.buttons["Undo"]
        XCTAssertTrue(waitUntil(Ceiling.ui) { undo.isHittable }, "Undo can't be tapped over the search panel")
        XCTAssertLessThanOrEqual(toast.settledFrame().maxY, field.frame.minY, "the toast covers the search field")

        undo.tapWhenSettled()
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "the search panel stayed over the page")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Home" }, "Undo didn't go back to Home")
        XCTAssertTrue(heading("/b", in: app).appears(within: Ceiling.load), "Undo didn't keep the page on screen")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launchWithSpaces(_ server: FixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingSpaces", server.url.absoluteString]
        app.launch()
        return app
    }

    private func open(_ url: URL, path: String, in app: XCUIApplication) {
        let field = app.textFields["Search or enter address"]
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "\(path) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        // The keyboard takes taps meant for the bar until it has gone.
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard stayed up")
    }

    private func openSwitcher(in app: XCUIApplication) {
        let tabs = tabsButton(in: app)
        XCTAssertTrue(tabs.appears(within: Ceiling.ui), "no tabs button")
        tabs.tapWhenSettled()
        XCTAssertTrue(app.buttons["Done"].appears(within: Ceiling.ui), "switcher didn't open")
    }

    /// The caret sheet, then its Move to Space row.
    private func openMoveSheet(in app: XCUIApplication) {
        app.buttons["Page actions"].tapWhenSettled()
        let row = app.buttons["MoveToSpaceRow"]
        XCTAssertTrue(row.appears(within: Ceiling.ui), "no Move to Space row in the caret sheet")
        row.tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Move to Space"].appears(within: Ceiling.ui), "the Move sheet didn't open")
    }

    /// Long-presses the card until its menu is up, then opens Move to Space.
    private func openCardMenu(on title: String, in app: XCUIApplication) {
        let card = card(title, in: app)
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for \(title)")
        let frame = card.settledFrame()
        let move = app.buttons["Move to Space"]
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        var opened = false
        for _ in 1...3 where !opened {
            center.press(forDuration: 1.2)
            opened = move.appears(within: Ceiling.ui)
        }
        XCTAssertTrue(opened, "the card's menu didn't open")
        XCTAssertTrue(app.buttons["Close Tab"].exists, "no Close Tab in the card's menu")
        move.tapWhenSettled()
    }

    /// Taps an item of a menu that's up, once it has stopped moving, and waits for the menu to go.
    private func chooseInMenu(_ item: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(item.appears(within: Ceiling.ui), "no \(item.description)")
        XCTAssertTrue(waitUntil(Ceiling.ui) { item.isHittable }, "\(item.description) isn't hittable")
        item.tapWhenSettled()
        XCTAssertTrue(item.disappears(within: Ceiling.ui), "the menu didn't close")
    }

    private func submenuItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != 'SpaceStrip'", name))
            .matching(NSPredicate(format: "elementType == %d OR elementType == %d OR elementType == %d",
                                  XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.toggle.rawValue,
                                  XCUIElement.ElementType.switch.rawValue))
            .firstMatch
    }

    private func destination(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'MoveDestination' AND label == %@", name)).firstMatch
    }

    private func card(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'TabCard' AND label == %@", title)).firstMatch
    }

    private func toast(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["Toast"].firstMatch
    }

    private func tabsButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    private func describe(_ element: XCUIElement) -> String {
        [element.label, element.value as? String].compactMap { $0 }.joined(separator: " | ")
    }
}
