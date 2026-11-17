import XCTest

/// Profiles, on screen: made from a Space's profile picker, which lists them under Manage Spaces;
/// changing a Space's profile is confirmed first; deleting one says what goes, and moves its Spaces to
/// Default. `-uiTestingSpaces` seeds Work, on the profile Vialumi, and Projects, with one fixture tab
/// each, and an empty Trip, beside an empty Home. Cookies and history staying in their profile, and a
/// deleted profile's data being erased, are CormorantTests' ProfilesTests.
@MainActor
final class ProfilesTests: UITestCase {
    /// The seeded tabs' page (none is shown here).
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1>Fixture</h1>
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

    func testDeletingAProfileMovesItsSpacesToDefault() throws {
        let server = try FixtureServer(html: Self.page)
        let app = launchWithSpaces(server)
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

        // Back in Manage Spaces: Vialumi gone, Work on Default.
        XCTAssertTrue(profileRow("Vialumi", in: app).disappears(within: Ceiling.ui), "Vialumi is still listed")
        XCTAssertTrue((profileRow("Default", in: app).value as? String)?.contains("Work") == true,
                      "Work isn't on Default: \(profileRow("Default", in: app).value ?? "nil")")
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

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    /// A profile's row in Manage Spaces: its name, with its color and the Spaces using it as the value.
    private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "ProfileRow")[name].firstMatch
    }

    /// A profile in the profile picker.
    private func choice(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "ProfileChoice")[name].firstMatch
    }

    private func closeSearch(in app: XCUIApplication) {
        // Near its top: the button lies behind the whole panel, which history rows make tall enough
        // to cover the button's middle.
        app.buttons["Close search"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(searchField(in: app).disappears(within: Ceiling.ui), "search panel didn't close")
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
        XCTAssertTrue(app.navigationBars["Spaces"].appears(within: Ceiling.ui), "Manage Spaces didn't open")
    }

    /// The back button of the page on top. On CI's iPhone Duo back buttons sit beside the bar, unlabeled;
    /// with pages pushed over Settings › Spaces there are several, and the one on top comes last.
    private func topBackButton(in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: "BackButton")
        return buttons.count > 1 ? buttons.element(boundBy: buttons.count - 1) : buttons.firstMatch
    }
}
