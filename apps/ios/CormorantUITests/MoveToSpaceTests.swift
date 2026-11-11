import XCTest

/// Moving a tab to another Space (a switcher card's long-press menu, the caret sheet's Move to Space
/// row), opening a link in another Space (the link menu's Open in Space), and the toasts that say where
/// the tab went: Undo and Back to the Space left after a move (which takes you with the tab), Show
/// after Open in Space, and Move… for a link from another app. `-uiTestingSpaces` seeds Work (on
/// the Vialumi profile, so moving there reloads) and Projects with one tab each, and an empty Trip,
/// beside Home. With only Home none of it shows.
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
        toast.buttons["Undo"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Home" }, "Undo didn't go back to Home")
        XCTAssertTrue(card("Tab /a", in: app).appears(within: Ceiling.ui), "Undo didn't bring the card back")
        XCTAssertTrue(card("Tab /b", in: app).exists, "Home lost its other card")
        XCTAssertTrue(toast.disappears(within: Ceiling.ui), "the toast stayed after Undo")

        // Again to Projects, then Back to Home: the card stays in Projects.
        openCardMenu(on: "Tab /a", in: app)
        chooseInMenu(submenuItem("Projects", in: app), in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the second move")
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Projects" }, "the switcher didn't go to Projects")
        toast.buttons["Back to Home"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { title.label == "Space, Home" }, "Back didn't go to Home")
        XCTAssertTrue(card("Tab /b", in: app).appears(within: Ceiling.ui), "Home's other card isn't there")
        XCTAssertFalse(card("Tab /a", in: app).exists, "the moved card came back with Back")
        app.buttons["Done"].tap()
        XCTAssertTrue(heading("/b", in: app).appears(within: Ceiling.load), "Home didn't show its tab")
        withExtendedLifetime(server) {}
    }

    /// From the caret sheet: the page on screen goes to Projects and stays on screen, the toast's Undo
    /// takes it back to Home, and its Back to Home shows Home's other tab, leaving it in Projects.
    func testMoveFromCaretSheetThenUndoAndBack() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)
        open(server.url.appending(path: "b"), path: "/b", in: app)

        openMoveSheet(in: app)
        let home = destination("Home", in: app), work = destination("Work", in: app)
        XCTAssertEqual(home.value as? String, "Here now")
        XCTAssertFalse(home.isEnabled, "the tab's own Space can be chosen")
        XCTAssertTrue((work.value as? String)?.contains("Reloads") == true, work.debugDescription)
        XCTAssertFalse((destination("Projects", in: app).value as? String)?.contains("Reloads") == true)
        XCTAssertFalse(app.buttons["New Space"].exists, "New Space is in the Move sheet")
        destination("Projects", in: app).tap()

        XCTAssertTrue(app.navigationBars["Move to Space"].disappears(within: Ceiling.ui), "the Move sheet stayed")
        XCTAssertTrue(app.buttons["Find on Page"].disappears(within: Ceiling.ui), "the caret sheet stayed")
        let toast = self.toast(in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the move")
        XCTAssertTrue(app.staticTexts["Moved to Projects"].exists)
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Projects" }, "the move didn't go to Projects")
        XCTAssertTrue(heading("/b", in: app).exists, "the moved page left the screen")
        XCTAssertEqual(tabsButton(in: app).label, "Tabs, 2 open", "Projects doesn't have the moved tab")

        toast.buttons["Undo"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Home" }, "Undo didn't go back to Home")
        XCTAssertTrue(heading("/b", in: app).appears(within: Ceiling.load), "Undo didn't keep the page on screen")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).label == "Tabs, 2 open" }, "Home's tabs didn't come back")

        openMoveSheet(in: app)
        destination("Projects", in: app).tap()
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the second move")
        toast.buttons["Back to Home"].tap()
        XCTAssertTrue(heading("/a", in: app).appears(within: Ceiling.load), "Back didn't show Home's other tab")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Home" }, "Back didn't go to Home")
        XCTAssertEqual(tabsButton(in: app).label, "Tabs, 1 open", "the moved tab came back with Back")
        withExtendedLifetime(server) {}
    }

    /// Moving a Space's last tab goes with it; Back to the Space left, empty now, brings up the search
    /// panel there.
    func testBackToASpaceLeftEmptyBringsUpTheSearchPanel() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)

        openMoveSheet(in: app)
        destination("Work", in: app).tap()
        let toast = self.toast(in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the move")
        XCTAssertTrue(heading("/a", in: app).appears(within: Ceiling.load), "the moved page isn't on screen in Work")
        let field = app.textFields["Search or enter address"]
        XCTAssertFalse(field.exists, "the search panel came up over the moved page")

        toast.buttons["Back to Home"].tap()
        XCTAssertTrue(field.appears(within: Ceiling.ui), "the empty Space didn't bring up the search panel")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Home" }, "Back didn't go to Home")
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
        destination("Projects", in: app).tap()
        let toast = self.toast(in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after the move")
        app.buttons["NewTabPill"].tapWhenSettled()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.ui), "New Tab didn't bring up the search panel")
        let undo = toast.buttons["Undo"]
        XCTAssertTrue(waitUntil(Ceiling.ui) { undo.isHittable }, "Undo can't be tapped over the search panel")
        XCTAssertLessThanOrEqual(toast.settledFrame().maxY, field.frame.minY, "the toast covers the search field")

        undo.tap()
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "the search panel stayed over the page")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Home" }, "Undo didn't go back to Home")
        XCTAssertTrue(heading("/b", in: app).appears(within: Ceiling.load), "Undo didn't keep the page on screen")
        withExtendedLifetime(server) {}
    }

    /// The link menu's Open in Space opens the link in a background tab there: no switch, a toast with
    /// Show, which goes to it.
    func testOpenInSpaceFromLinkMenuDoesNotSwitch() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)

        let openInSpace = app.buttons["Open in Space"]
        XCTAssertTrue(pressForLinkMenu(app.webViews.links["Next page"], until: openInSpace, in: app), "no Open in Space")
        XCTAssertTrue(app.buttons["Open in Background Tab"].exists, "Open in Background Tab left the menu")
        openInSpace.tapWhenSettled()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Projects'")).firstMatch
        XCTAssertTrue(projects.appears(within: Ceiling.ui), "no Projects under Open in Space")
        // Only the other Spaces, each with its profile where it isn't the default.
        let work = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Work'")).firstMatch
        XCTAssertTrue(describe(work).contains("Vialumi profile"), describe(work))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home'")).firstMatch.exists,
                       "the current Space is under Open in Space")
        XCTAssertFalse(app.buttons["New Space"].exists, "New Space is under Open in Space")
        projects.tapWhenSettled()
        XCTAssertTrue(projects.disappears(within: Ceiling.ui), "the menu didn't close")
        app.waitsForAnimations = true

        let toast = self.toast(in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after Open in Space")
        XCTAssertTrue(app.staticTexts["Opened in Projects"].exists)
        XCTAssertTrue(heading("/a", in: app).exists, "Open in Space left the page")
        XCTAssertEqual(tabsButton(in: app).value as? String, "Home", "Open in Space switched Spaces")
        XCTAssertEqual(tabsButton(in: app).label, "Tabs, 1 open", "the tab opened in Home")

        toast.buttons["Show"].tap()
        XCTAssertTrue(heading("/next", in: app).appears(within: Ceiling.load), "Show didn't show the new tab")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Projects" }, "Show didn't switch to Projects")
        XCTAssertEqual(tabsButton(in: app).label, "Tabs, 2 open", "Projects doesn't have the new tab")
        withExtendedLifetime(server) {}
    }

    /// A link from another app opens in the Space you're in, straight to the page; the toast says which
    /// and its Move… moves it on, the page with you. The toast can be swiped away.
    func testLinkFromAnotherAppShowsWhereItOpened() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        open(server.url.appending(path: "a"), path: "/a", in: app)

        openFromAnotherApp(server.url.appending(path: "shared"), in: app)
        XCTAssertTrue(heading("/shared", in: app).appears(within: Ceiling.load), "the link didn't open")
        let toast = self.toast(in: app)
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast for a link from another app")
        XCTAssertTrue(app.staticTexts["Opened in Home"].exists, "the toast doesn't name the Space")

        toast.buttons["Move…"].tap()
        XCTAssertTrue(app.navigationBars["Move to Space"].appears(within: Ceiling.ui), "Move… didn't open the Move sheet")
        destination("Work", in: app).tap()
        XCTAssertTrue(app.staticTexts["Moved to Work"].appears(within: Ceiling.ui), "no toast after Move…")
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.tabsButton(in: app).value as? String == "Work" }, "Move… didn't go to Work")
        XCTAssertTrue(heading("/shared", in: app).appears(within: Ceiling.load), "the moved page left the screen")

        toast.swipeDown()
        XCTAssertTrue(toast.disappears(within: Ceiling.ui), "the toast didn't swipe away")
        withExtendedLifetime(server) {}
    }

    /// Left alone, a toast goes by itself (`-uiTestingToastSeconds`: UI tests keep toasts up otherwise).
    /// Seen through the app's count of toasts (`UITestingProbes`), not on screen: it may have gone by the
    /// time a slow runner first looks.
    func testToastGoesAwayOnItsOwn() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingSpaces", server.url.absoluteString, "-uiTestingToastSeconds", "1"]
        app.launch()
        open(server.url.appending(path: "a"), path: "/a", in: app)
        let toasts = app.descendants(matching: .any)["UITesting.toasts"].firstMatch
        XCTAssertEqual(toasts.value as? String, "0 none")

        openFromAnotherApp(server.url.appending(path: "shared"), in: app)
        XCTAssertTrue(heading("/shared", in: app).appears(within: Ceiling.load), "the link didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { toasts.value as? String == "1 none" },
                      "the toast didn't come and go: \(toasts.value as? String ?? "no probe")")
        withExtendedLifetime(server) {}
    }

    /// With only Home: no Move to Space row, no card menu, no Open in Space, and no toast for a link
    /// from another app.
    func testOneSpaceShowsNoMovesOrToasts() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        open(server.url.appending(path: "a"), path: "/a", in: app)

        app.buttons["Page actions"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Find on Page"].appears(within: Ceiling.ui), "caret sheet didn't open")
        XCTAssertFalse(app.buttons["MoveToSpaceRow"].exists, "Move to Space shows with only Home")
        // Closed by a tap above it, on the page.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["Find on Page"].disappears(within: Ceiling.ui), "caret sheet didn't close")

        XCTAssertTrue(pressForLinkMenu(app.webViews.links["Next page"], until: app.buttons["Open in Background Tab"], in: app),
                      "no link menu")
        XCTAssertFalse(app.buttons["Open in Space"].exists, "Open in Space shows with only Home")
        dismissLinkMenu(beside: app.buttons["Copy Link"], in: app)

        openSwitcher(in: app)
        card("Tab /a", in: app).press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Move to Space"].appears(within: 2), "a card has a Move menu with only Home")
        // A long press may also count as a tap on the card, which opens its tab.
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        XCTAssertTrue(app.buttons["Done"].disappears(within: Ceiling.ui), "the switcher didn't close")

        openFromAnotherApp(server.url.appending(path: "shared"), in: app)
        XCTAssertTrue(heading("/shared", in: app).appears(within: Ceiling.load), "the link didn't open")
        XCTAssertFalse(toast(in: app).appears(within: 2), "a toast with only Home")
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

    /// As the system hands the app a link another app opened, with Cormorant the default browser.
    /// Through the system: `XCUIApplication.open(_:)` relaunches the app, losing its tabs.
    private func openFromAnotherApp(_ url: URL, in app: XCUIApplication) {
        var components = URLComponents(string: "cormorant://open")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        XCUIDevice.shared.system.open(components.url!)
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
        row.tap()
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
