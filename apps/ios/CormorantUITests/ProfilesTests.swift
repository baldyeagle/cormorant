import XCTest

/// Profiles keep website data apart: a cookie set in one profile isn't seen in another, and the search
/// panel's history comes from the active Space's profile only. Made in Manage Spaces or from a Space's
/// profile picker; changing a Space's profile is confirmed first; deleting a profile moves its Spaces to
/// Default, whose website data their tabs then load with. `-uiTestingSpaces` seeds Work, on the
/// profile Vialumi, and Projects, with one fixture tab each, and an empty Trip, beside an empty Home.
@MainActor
final class ProfilesTests: UITestCase {
    /// Every path serves this page. It names its path, sets the cookie `probe` to whatever follows
    /// `/set/`, and shows the `probe` this profile's website data has.
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <p id="cookie">Cookie</p>
        <script>
          const set = location.pathname.match(/^\\/set\\/(\\w+)$/)
          if (set) document.cookie = 'probe=' + set[1] + '; path=/; max-age=86400'
          const probe = document.cookie.split('; ').find(c => c.startsWith('probe='))
          document.getElementById('path').textContent = 'Path ' + location.pathname
          document.getElementById('cookie').textContent = 'Cookie ' + (probe || 'none')
          document.title = 'Page ' + location.pathname.slice(1)
        </script>
        """

    func testCreatingAProfileFromNewSpace() {
        let app = launch()
        openSpaces(in: app)
        // With one profile, the section is there with Default, used by Home.
        XCTAssertTrue(profileRow("Default", in: app).appears(within: Ceiling.ui), "no Profiles section")
        XCTAssertTrue((profileRow("Default", in: app).value as? String)?.hasSuffix("Home") == true,
                      "Default doesn't list Home: \(profileRow("Default", in: app).value ?? "nil")")

        app.buttons["New Space"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.appears(within: Ceiling.ui), "New Space didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { name.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the name field didn't take focus")
        name.typeText("Work")
        // New Space starts on Default. Below the icons and colors: scrolled to, on the preview (a swipe
        // starting on a button can land as a tap on it).
        app.otherElements["Preview"].firstMatch.swipeUp()
        let profile = app.buttons["SpaceProfile"]
        XCTAssertTrue(profile.appears(within: Ceiling.ui), "no Profile row")
        XCTAssertEqual(profile.label, "Default")
        profile.tap()
        let newProfile = app.buttons["New Profile…"]
        XCTAssertTrue(newProfile.appears(within: Ceiling.ui), "the profile picker didn't open")
        XCTAssertTrue(choice("Default", in: app).isSelected, "Default isn't checked")
        newProfile.tap()

        XCTAssertTrue(app.staticTexts["The Space you're creating"].appears(within: Ceiling.ui), "New Profile didn't open")
        let profileName = app.textFields["ProfileName"]
        XCTAssertTrue(waitUntil(Ceiling.ui) { profileName.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the name field didn't take focus")
        profileName.typeText("Vialumi")
        app.buttons["Indigo"].tap()
        app.buttons["Add"].tap()

        // Back on the picker, the new profile chosen (a new Space has no tabs to warn about).
        let vialumi = choice("Vialumi", in: app)
        XCTAssertTrue(vialumi.appears(within: Ceiling.ui), "the new profile isn't in the picker")
        XCTAssertTrue(waitUntil(Ceiling.ui) { vialumi.isSelected }, "the new profile isn't chosen")
        topBackButton(in: app).tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { profile.label == "Vialumi" }, "the Profile row says \(profile.label)")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Spaces"].disappears(within: Ceiling.ui), "Manage Spaces didn't close")

        // Listed under Profiles, used by Work.
        openSpaces(in: app)
        let row = profileRow("Vialumi", in: app)
        XCTAssertTrue(row.appears(within: Ceiling.ui), "Vialumi isn't listed")
        XCTAssertEqual(row.value as? String, "Indigo, Work")
        XCTAssertEqual(profileRow("Default", in: app).value as? String, "Blue, Home")
        // And Work's row names its profile; Home's, on Default, doesn't.
        XCTAssertEqual(app.buttons["Work"].firstMatch.value as? String, "Briefcase icon, Indigo, 0 tabs · Vialumi")
        XCTAssertEqual(app.buttons["Home"].firstMatch.value as? String, "House icon, Teal, 0 tabs")
    }

    func testChangingASpacesProfileIsConfirmed() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        openSpaces(in: app)
        app.buttons["Work"].firstMatch.tap()
        let profile = app.buttons["SpaceProfile"]
        XCTAssertTrue(profile.appears(within: Ceiling.ui), "Edit Space didn't open")
        XCTAssertEqual(profile.label, "Vialumi")
        profile.tap()

        let personal = choice("Default", in: app)
        XCTAssertTrue(personal.appears(within: Ceiling.ui), "the profile picker didn't open")
        personal.tap()
        let alert = app.alerts["Switch Work to Default?"]
        XCTAssertTrue(alert.appears(within: Ceiling.ui), "no confirmation")
        XCTAssertTrue(alert.staticTexts["Work's tab reloads with Default's logins and cookies. Nothing in Vialumi is deleted."].exists,
                      "the confirmation doesn't say what happens")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.disappears(within: Ceiling.ui), "the confirmation didn't close")
        XCTAssertTrue(choice("Vialumi", in: app).isSelected, "Cancel changed the profile")

        // A profile made from here is confirmed too, once the picker is back.
        app.buttons["New Profile…"].tap()
        let name = app.textFields["ProfileName"]
        XCTAssertTrue(name.appears(within: Ceiling.ui), "New Profile didn't open")
        XCTAssertTrue(waitUntil(Ceiling.ui) { name.value(forKey: "hasKeyboardFocus") as? Bool == true },
                      "the name field didn't take focus")
        name.typeText("Clients")
        app.buttons["Add"].tap()
        let clients = app.alerts["Switch Work to Clients?"]
        XCTAssertTrue(clients.appears(within: Ceiling.ui), "no confirmation for the new profile")
        clients.buttons["Cancel"].tap()
        XCTAssertTrue(clients.disappears(within: Ceiling.ui), "the confirmation didn't close")
        XCTAssertTrue(choice("Clients", in: app).exists, "the new profile isn't in the picker")
        XCTAssertTrue(choice("Vialumi", in: app).isSelected, "Cancel changed the profile")

        personal.tap()
        XCTAssertTrue(alert.appears(within: Ceiling.ui), "no confirmation the second time")
        alert.buttons["Switch"].tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { personal.isSelected }, "Switch didn't choose Default")
        topBackButton(in: app).tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { profile.label == "Default" }, "the Profile row says \(profile.label)")
        XCTAssertEqual(profile.value as? String, "Blue, Its tab reloads when you save")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Save"].disappears(within: Ceiling.ui), "Edit Space didn't close")
        XCTAssertTrue(waitUntil(Ceiling.ui) { (self.profileRow("Default", in: app).value as? String)?.contains("Work") == true },
                      "Work isn't on Default: \(profileRow("Default", in: app).value ?? "nil")")
        XCTAssertEqual(profileRow("Vialumi", in: app).value as? String, "Indigo, No Spaces")
        withExtendedLifetime(server) {}
    }

    func testCookiesStayInTheirProfile() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        let home = token(), work = token()
        open(server.url.appending(path: "set/\(home)"), path: "/set/\(home)", in: app)
        XCTAssertTrue(cookie(home, in: app).appears(within: Ceiling.load), "Home's cookie wasn't set")

        // Work is on Vialumi: Home's cookie isn't there.
        switchTo("Work", in: app)
        XCTAssertTrue(heading("/work", in: app).appears(within: Ceiling.load), "Work's tab didn't show")
        XCTAssertTrue(cookie(nil, in: app).appears(within: Ceiling.load), "Work sees a cookie: \(cookieText(in: app))")
        open(server.url.appending(path: "set/\(work)"), path: "/set/\(work)", in: app)
        XCTAssertTrue(cookie(work, in: app).appears(within: Ceiling.load), "Work's cookie wasn't set")

        // And Work's isn't in Default: Home still has its own.
        switchTo("Home", in: app)
        open(server.url.appending(path: "check"), path: "/check", in: app)
        XCTAssertTrue(cookie(home, in: app).appears(within: Ceiling.load), "Home's cookie changed: \(cookieText(in: app))")
        withExtendedLifetime(server) {}
    }

    func testDeletingAProfileMovesItsSpacesToDefault() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        let home = token()
        open(server.url.appending(path: "set/\(home)"), path: "/set/\(home)", in: app)
        XCTAssertTrue(cookie(home, in: app).appears(within: Ceiling.load), "Home's cookie wasn't set")
        switchTo("Work", in: app)
        XCTAssertTrue(heading("/work", in: app).appears(within: Ceiling.load), "Work's tab didn't show")
        XCTAssertTrue(cookie(nil, in: app).appears(within: Ceiling.load), "Work sees a cookie: \(cookieText(in: app))")

        openSpaces(in: app)
        profileRow("Vialumi", in: app).tap()
        let monogram = app.descendants(matching: .any)["Monogram"].firstMatch
        XCTAssertTrue(monogram.appears(within: Ceiling.ui), "Edit Profile didn't open")
        let usedBy = app.descendants(matching: .any).matching(identifier: "ProfileSpace").firstMatch
        XCTAssertTrue(usedBy.label.hasPrefix("Work"), "Edit Profile doesn't list Work: \(usedBy.label)")
        monogram.swipeUp()
        let delete = app.buttons["Delete Profile"]
        XCTAssertTrue(delete.appears(within: Ceiling.ui), "no Delete Profile")
        let footer = "Deleting signs you out of every site in Vialumi and erases its cookies, website data and history. Work switches to Default."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", footer)).firstMatch.exists,
                      "the footer doesn't say what goes")
        delete.tap()
        let alert = app.alerts["Delete Vialumi?"]
        XCTAssertTrue(alert.appears(within: Ceiling.ui), "no delete confirmation")
        let message = "You'll be signed out of every site in this profile, and its cookies, website data and history are erased. Work switches to Default and reloads. This can't be undone."
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label == %@", message)).firstMatch.exists,
                      "the alert doesn't name the data loss")
        alert.buttons["Delete"].tap()

        // Back in Manage Spaces: Vialumi gone, Work on Default, and its data erased.
        XCTAssertTrue(profileRow("Vialumi", in: app).disappears(within: Ceiling.ui), "Vialumi is still listed")
        XCTAssertTrue((profileRow("Default", in: app).value as? String)?.contains("Work") == true,
                      "Work isn't on Default: \(profileRow("Default", in: app).value ?? "nil")")

        // Work's tab loaded again with Default's website data. Vialumi's is erased once nothing shows
        // its old page (the caret sheet under Settings keeps the tab it opened with until it closes).
        leaveSettings(in: app)
        XCTAssertTrue(cookie(home, in: app).appears(within: Ceiling.load), "Work's tab isn't on Default: \(cookieText(in: app))")
        let erasing = app.descendants(matching: .any)["UITesting.erasing"].firstMatch
        // WebKit only lets a store go once the web views on it have: a load's ceiling, not the UI's.
        XCTAssertTrue(waitUntil(Ceiling.load) { erasing.value as? String == "0" }, "Vialumi's data wasn't erased")
        withExtendedLifetime(server) {}
    }

    func testHistoryFollowsTheProfile() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
        // A page only in each profile's history: visited, then left in the same tab.
        open(server.url.appending(path: "alpha"), path: "/alpha", in: app)
        replacePage("alpha", with: server.url.appending(path: "gamma"), in: app)
        switchTo("Work", in: app)
        XCTAssertTrue(heading("/work", in: app).appears(within: Ceiling.load), "Work's tab didn't show")
        open(server.url.appending(path: "beta"), path: "/beta", in: app)
        replacePage("beta", with: server.url.appending(path: "delta"), in: app)

        // In Work, Vialumi's history: beta, not alpha.
        var field = newTabField(in: app)
        field.typeText("page")
        XCTAssertTrue(historyRow("beta", in: app).appears(within: Ceiling.ui), "Work's history doesn't have beta")
        XCTAssertFalse(historyRow("alpha", in: app).exists, "Work suggests Home's history")
        closeSearch(in: app)

        // In Home, Default's: alpha, not beta.
        switchTo("Home", in: app)
        field = newTabField(in: app)
        field.typeText("page")
        XCTAssertTrue(historyRow("alpha", in: app).appears(within: Ceiling.ui), "Home's history doesn't have alpha")
        XCTAssertFalse(historyRow("beta", in: app).exists, "Home suggests Work's history")
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(searchField(in: app).appears(within: Ceiling.launch), "no search panel at launch")
        return app
    }

    private func launchWithSpaces(_ server: FixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingSpaces", server.url.absoluteString]
        app.launch()
        XCTAssertTrue(searchField(in: app).appears(within: Ceiling.launch), "no search panel at launch")
        return app
    }

    /// A cookie value no earlier run can have left in the simulator's default website data.
    private func token() -> String { "t" + UUID().uuidString.prefix(8).lowercased() }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    /// The page's report of its `probe` cookie: `value`, or none.
    private func cookie(_ value: String?, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Cookie \(value.map { "probe=\($0)" } ?? "none")"].firstMatch
    }

    private func cookieText(in app: XCUIApplication) -> String {
        app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cookie '")).firstMatch.label
    }

    /// A profile's row in Manage Spaces: its name, with its color and the Spaces using it as the value.
    private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "ProfileRow")[name].firstMatch
    }

    /// A profile in the profile picker.
    private func choice(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "ProfileChoice")[name].firstMatch
    }

    private func historyRow(_ page: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND value ENDSWITH 'history'", "Page \(page)")).firstMatch
    }

    /// Opens `url` from the search panel, or in a new tab.
    private func open(_ url: URL, path: String, in app: XCUIApplication) {
        let field = searchField(in: app)
        if !field.exists { app.buttons["NewTabPill"].tapWhenSettled() }
        XCTAssertTrue(field.appears(within: Ceiling.ui), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(path, in: app).appears(within: Ceiling.load), "\(path) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard stayed up")
    }

    /// Loads `url` in the tab showing `/page`, so that page is left only in history.
    private func replacePage(_ page: String, with url: URL, in app: XCUIApplication) {
        app.buttons["NewTabPill"].tapWhenSettled()
        let edit = app.buttons["Edit address: Page \(page)"]
        XCTAssertTrue(edit.appears(within: Ceiling.ui), "no Edit row")
        edit.tap()
        let field = searchField(in: app)
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(heading(url.path(), in: app).appears(within: Ceiling.load), "\(url.path()) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard stayed up")
    }

    /// The bar's + panel's field, focused and empty.
    private func newTabField(in app: XCUIApplication) -> XCUIElement {
        app.buttons["NewTabPill"].tapWhenSettled()
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.ui), "+ didn't open the search panel")
        XCTAssertTrue(waitUntil(Ceiling.ui) { field.value(forKey: "hasKeyboardFocus") as? Bool == true }, "field not focused")
        return field
    }

    private func closeSearch(in app: XCUIApplication) {
        // Near its top: the button lies behind the whole panel, which history rows make tall enough
        // to cover the button's middle.
        app.buttons["Close search"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(searchField(in: app).disappears(within: Ceiling.ui), "search panel didn't close")
        XCTAssertTrue(app.keyboardIsDown(), "the keyboard stayed up")
    }

    /// Switches Space with the switcher's strip.
    private func switchTo(_ space: String, in app: XCUIApplication) {
        if searchField(in: app).exists { closeSearch(in: app) }
        let tabs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch
        XCTAssertTrue(tabs.appears(within: Ceiling.ui), "no tabs button")
        tabs.tapWhenSettled()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.appears(within: Ceiling.ui), "switcher didn't open")
        let glyph = app.buttons.matching(identifier: "SpaceStrip")[space]
        glyph.tap()
        XCTAssertTrue(waitUntil(Ceiling.ui) { app.buttons["SpaceTitleMenu"].label == "Space, \(space)" },
                      "the strip didn't switch to \(space)")
        done.tap()
        XCTAssertTrue(done.disappears(within: Ceiling.ui), "the switcher didn't close")
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
        XCTAssertTrue(app.navigationBars["Spaces"].appears(within: Ceiling.ui), "Manage Spaces didn't open")
    }

    /// The back button of the page on top. On CI's iPhone Duo back buttons sit beside the bar, unlabeled;
    /// with pages pushed over Settings › Spaces there are several, and the one on top comes last.
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
}
