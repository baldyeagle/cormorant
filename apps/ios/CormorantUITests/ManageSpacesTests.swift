import XCTest

/// Manage Spaces, reached from Settings: adding a Space lands in it, empty, with the search panel up;
/// Edit Space renames a Space and changes its icon; archiving keeps a Space for Restore; deleting sends
/// its tabs to the tab archive; Home can't be archived or deleted.
@MainActor
final class ManageSpacesTests: UITestCase {
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

    func testNewSpaceOpensEmptyWithTheSearchPanel() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        open(server.url.appending(path: "home"), path: "/home", in: app)

        openSpaces(in: app)
        app.buttons["New Space"].tap()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.appears(within: Ceiling.ui), "New Space didn't open")
        XCTAssertFalse(add.isEnabled, "Add is enabled with no name")
        let name = app.textFields["Name"]
        XCTAssertTrue(waitUntil(Ceiling.ui) { name.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the name field didn't take focus")
        name.typeText("Work")
        add.tap()

        // Straight into Work: Manage Spaces gone, Home's page with it, and the search panel up.
        XCTAssertTrue(app.navigationBars["Spaces"].disappears(within: Ceiling.ui), "Manage Spaces didn't close")
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.ui), "no search panel in the new Space")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the search field has no focus")
        XCTAssertTrue(heading("/home", in: app).disappears(within: Ceiling.ui), "Home's page is still showing")
        closeSearch(in: app)
        XCTAssertTrue(app.buttons["Tabs, 0 open"].appears(within: Ceiling.ui), "the new Space isn't empty")

        // Listed after Home, which keeps its tab.
        openSpaces(in: app)
        XCTAssertEqual(row("Home", in: app).value as? String, "House icon, Teal, 1 tab")
        XCTAssertEqual(row("Work", in: app).value as? String, "Briefcase icon, Indigo, 0 tabs")
        XCTAssertLessThan(row("Home", in: app).frame.minY, row("Work", in: app).frame.minY)
        withExtendedLifetime(server) {}
    }

    func testRenamingHomeAndNoArchiveOrDelete() {
        let app = launch()
        openSpaces(in: app)
        row("Home", in: app).tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.appears(within: Ceiling.ui), "Edit Space didn't open")
        // Home always exists: renamed, never archived or deleted. Checked with the form scrolled to its
        // end, the archive time's footer, where Archive and Delete would follow.
        app.otherElements["Preview"].firstMatch.swipeUp()
        let footer = app.staticTexts["Tabs you haven't looked at for this long move to the tab archive."]
        XCTAssertTrue(footer.appears(within: Ceiling.ui), "no archive time for Home")
        XCTAssertFalse(app.buttons["Archive Space"].exists, "Home offers Archive")
        XCTAssertFalse(app.buttons["Delete Space"].exists, "Home offers Delete")

        replaceName(with: "Personal", in: app)
        save.tap()
        XCTAssertTrue(save.disappears(within: Ceiling.ui), "Edit Space didn't close")
        XCTAssertTrue(row("Personal", in: app).appears(within: Ceiling.ui), "Home wasn't renamed")
        XCTAssertFalse(row("Home", in: app).exists, "the old name is still listed")
    }

    func testChangingASpacesIcon() {
        let app = launch()
        createSpace("Work", in: app)
        openSpaces(in: app)
        row("Work", in: app).tap()
        XCTAssertTrue(app.buttons["Save"].appears(within: Ceiling.ui), "Edit Space didn't open")

        app.buttons["Icon and Color"].tap()
        let airplane = app.buttons["Airplane"]
        XCTAssertTrue(airplane.appears(within: Ceiling.ui), "Icon and Color didn't open")
        airplane.tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { airplane.isSelected }, "Airplane wasn't chosen")
        // Not in the navigation bar on every phone: the iPhone Duo's are in a column at the side.
        topBackButton(in: app).tap()
        XCTAssertTrue(airplane.disappears(within: Ceiling.ui), "didn't go back to Edit Space")

        let save = app.buttons["Save"]
        save.tap()
        XCTAssertTrue(save.disappears(within: Ceiling.ui), "Edit Space didn't close")
        XCTAssertTrue(waitUntil(Ceiling.ui) { (self.row("Work", in: app).value as? String)?.hasPrefix("Airplane icon") == true },
                      "the icon didn't change: \(row("Work", in: app).value ?? "nil")")
    }

    func testArchivingAndRestoringASpace() {
        let app = launch()
        createSpace("Work", in: app)
        openSpaces(in: app)
        row("Work", in: app).tap()
        let archive = app.buttons["Archive Space"]
        XCTAssertTrue(archive.appears(within: Ceiling.ui), "Edit Space didn't open")
        archive.tap()
        let confirm = app.buttons["Archive Work"]
        XCTAssertTrue(confirm.appears(within: Ceiling.ui), "no archive confirmation")
        XCTAssertTrue(app.staticTexts["It has no open tabs. Work leaves the Spaces you switch between until you restore it from Archived in Spaces."].exists,
                      "the confirmation doesn't say how to get it back")
        confirm.tap()
        XCTAssertTrue(app.buttons["Save"].disappears(within: Ceiling.ui), "Edit Space didn't close")

        // Out of the list, into Archived.
        let restore = app.buttons["Restore Work"]
        XCTAssertTrue(restore.appears(within: Ceiling.ui), "Work isn't under Archived")
        XCTAssertFalse(app.buttons["Work"].exists, "Work is still in the list")
        restore.tap()
        XCTAssertTrue(row("Work", in: app).appears(within: Ceiling.ui), "Restore didn't bring Work back")
        XCTAssertTrue(restore.disappears(within: Ceiling.ui), "Work is still under Archived")
    }

    func testTheCurrentSpaceIsCheckedAndAnArchivedOneDeletesFromTheList() {
        let app = launch()
        createSpace("Work", in: app)
        openSpaces(in: app)
        XCTAssertTrue(row("Work", in: app).isSelected, "Work, the Space you're in, isn't checked")
        XCTAssertFalse(row("Home", in: app).isSelected, "Home is checked though you're in Work")

        row("Work", in: app).tap()
        let archive = app.buttons["Archive Space"]
        XCTAssertTrue(archive.appears(within: Ceiling.ui), "Edit Space didn't open")
        archive.tap()
        let confirmArchive = app.buttons["Archive Work"]
        XCTAssertTrue(confirmArchive.appears(within: Ceiling.ui), "no archive confirmation")
        confirmArchive.tap()
        XCTAssertTrue(app.buttons["Save"].disappears(within: Ceiling.ui), "Edit Space didn't close")
        XCTAssertTrue(row("Home", in: app).isSelected, "archiving the Space you're in didn't check Home")

        // Swiped off the Archived section, without restoring it first; confirmed as in Edit Space.
        let restore = app.buttons["Restore Work"]
        XCTAssertTrue(restore.appears(within: Ceiling.ui), "Work isn't under Archived")
        let archivedHeader = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Archived'")).firstMatch
        XCTAssertTrue(archivedHeader.exists, "no Archived section")
        app.cells.containing(.button, identifier: "Restore Work").firstMatch.swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.appears(within: Ceiling.ui), "no Delete on the archived row")
        swipeDelete.tap()
        let confirm = app.buttons["Delete Work"]
        XCTAssertTrue(confirm.appears(within: Ceiling.ui), "no delete confirmation")
        XCTAssertTrue(app.staticTexts["It has no open tabs. The Space and its settings are gone."].exists,
                      "the confirmation doesn't say what goes")
        confirm.tap()
        XCTAssertTrue(restore.disappears(within: Ceiling.ui), "Work is still under Archived")
        XCTAssertFalse(row("Work", in: app).exists, "Work came back to the list instead of going")
        XCTAssertFalse(archivedHeader.exists, "the empty Archived section stayed")
    }

    func testDeletingASpaceSendsItsTabsToTheArchive() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launch()
        createSpace("Work", in: app)
        open(server.url.appending(path: "work"), path: "/work", in: app)

        openSpaces(in: app)
        XCTAssertEqual(row("Work", in: app).value as? String, "Briefcase icon, Indigo, 1 tab")
        row("Work", in: app).tap()
        // Below the fold on a short screen, where the form hasn't made it yet.
        let archive = app.buttons["Archive Space"]
        XCTAssertTrue(archive.appears(within: Ceiling.ui), "Edit Space didn't open")
        // On the preview: a swipe starting on a button can land as a tap on it.
        app.otherElements["Preview"].firstMatch.swipeUp()
        let delete = app.buttons["Delete Space"]
        XCTAssertTrue(delete.appears(within: Ceiling.ui), "no Delete Space")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete Work?"].appears(within: Ceiling.ui), "no delete confirmation")
        XCTAssertTrue(app.staticTexts["Its tab goes to the tab archive, where you can search for it and reopen it. The Space and its settings are gone."].exists,
                      "the confirmation doesn't say where the tab goes")
        app.buttons["Delete Work"].tap()

        XCTAssertTrue(app.buttons["Save"].disappears(within: Ceiling.ui), "Edit Space didn't close")
        XCTAssertTrue(row("Work", in: app).disappears(within: Ceiling.ui), "Work is still listed")
        // Settings stays up through it, back in Home.
        XCTAssertTrue(row("Home", in: app).isSelected, "Home isn't the current Space")
        leaveSettings(in: app)

        // Back in Home, empty; Work's page is in the tab archive.
        XCTAssertTrue(searchField(in: app).appears(within: Ceiling.ui), "no search panel in empty Home")
        closeSearch(in: app)
        let tabs = app.buttons["Tabs, 0 open"]
        XCTAssertTrue(tabs.appears(within: Ceiling.ui), "Home isn't empty")
        let archiveLink = app.buttons["Archive"]
        tabs.tapWhenSettled()
        XCTAssertTrue(archiveLink.appears(within: Ceiling.ui), "the switcher didn't open")
        archiveLink.tap()
        XCTAssertTrue(app.staticTexts["Tab /work"].appears(within: Ceiling.ui), "Work's tab isn't in the archive")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        // `TEST_RUNNER_SHOW_TOUCHES=1 xcodebuild test ...`: dots where taps land, for the recording.
        if ProcessInfo.processInfo.environment["SHOW_TOUCHES"] == "1" { app.launchArguments.append("-uiTestingShowTouches") }
        app.launch()
        XCTAssertTrue(searchField(in: app).appears(within: Ceiling.launch), "no search panel at launch")
        return app
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    /// A Space's row in Manage Spaces: its name, with its icon, color and tabs as the value.
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[name].firstMatch
    }

    private func open(_ url: URL, path: String, in app: XCUIApplication) {
        let field = searchField(in: app)
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.ui), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "\(path) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
    }

    private func closeSearch(in app: XCUIApplication) {
        // Near its top: the button lies behind the whole panel, which a history row makes tall enough
        // to cover the button's middle.
        app.buttons["Close search"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(searchField(in: app).disappears(within: Ceiling.ui), "search panel didn't close")
        // The bar is back in the tree as soon as the keyboard starts down, but the keyboard is still
        // over it, taking taps meant for its buttons, until it has gone.
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard stayed up")
    }

    /// Settings › Spaces, from wherever the browser is.
    private func openSpaces(in app: XCUIApplication) {
        if searchField(in: app).exists { closeSearch(in: app) }
        app.buttons["Page actions"].tapWhenSettled()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.appears(within: Ceiling.ui), "caret sheet didn't open")
        settings.tap()
        let spaces = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Spaces'")).firstMatch
        XCTAssertTrue(spaces.appears(within: Ceiling.ui), "Settings didn't open")
        spaces.tap()
        // Pushed in Settings, like its other pages.
        XCTAssertTrue(app.navigationBars["Spaces"].appears(within: Ceiling.ui), "Manage Spaces didn't open")
        // Its back button (beside the bar, not in it, on CI's iPhone Duo).
        XCTAssertTrue(topBackButton(in: app).appears(within: Ceiling.ui), "Manage Spaces isn't a page in Settings")
    }

    /// The back button of the page on top. On CI's iPhone Duo back buttons sit beside the bar, unlabeled;
    /// with Edit Space's pages over Settings › Spaces there are two, and the one on top comes last.
    private func topBackButton(in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: "BackButton")
        return buttons.count > 1 ? buttons.element(boundBy: buttons.count - 1) : buttons.firstMatch
    }

    /// Back out of Settings › Spaces: to Settings, Done, then the caret sheet swiped away by its grabber.
    private func leaveSettings(in app: XCUIApplication) {
        topBackButton(in: app).tap()
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.appears(within: Ceiling.ui), "didn't go back to Settings")
        done.tap()
        let grabber = app.descendants(matching: .any)["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.appears(within: Ceiling.ui), "the caret sheet isn't up")
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(grabber.disappears(within: Ceiling.ui), "the caret sheet didn't close")
    }

    /// Adds a Space with the suggested look and lands in it, with the search panel up.
    private func createSpace(_ name: String, in app: XCUIApplication) {
        openSpaces(in: app)
        app.buttons["New Space"].tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.appears(within: Ceiling.ui), "New Space didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the name field didn't take focus")
        field.typeText(name)
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Spaces"].disappears(within: Ceiling.ui), "Manage Spaces didn't close")
        XCTAssertTrue(searchField(in: app).appears(within: Ceiling.ui), "no search panel in \(name)")
    }

    /// Clears Edit Space's name field and types `name`.
    private func replaceName(with name: String, in app: XCUIApplication) {
        let field = app.textFields["Name"]
        XCTAssertTrue(field.appears(within: Ceiling.ui))
        field.tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the name field didn't take focus")
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
    }
}
