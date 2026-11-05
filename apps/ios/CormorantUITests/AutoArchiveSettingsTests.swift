import XCTest

/// Settings' Archive Idle Tabs: the switch turns auto-archive off for every Space at once and back on
/// with each Space's own time, Off keeps idle tabs open, and both survive a relaunch.
@MainActor
final class AutoArchiveSettingsTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        """

    /// Two days, past the 24-hour default.
    private static let twoDays = "172800"

    func testOffStaysOffAfterRelaunchAndOnComesBackAtItsTime() throws {
        let server = try FixtureServer(html: Self.page)
        let session = UUID().uuidString
        var app = launch(session: session, server: server)
        openSettings(in: app)
        let toggle = archiveSwitch(in: app)
        XCTAssertEqual(toggle.value as? String, "1", "auto-archive isn't on by default")
        XCTAssertEqual(time(of: timeRow("After", in: app)), "24 Hours")

        setSwitch(toggle, on: false)
        // Dimmed, with the time that comes back.
        XCTAssertTrue(waitUntil(Ceiling.ui) { !self.timeRow("After", in: app).isEnabled }, "the time is still enabled with archiving off")
        XCTAssertEqual(time(of: timeRow("After", in: app)), "24 Hours")
        XCTAssertTrue(footer(containing: "Tabs stay open until you close them.", in: app).exists)

        closeSettings(in: app)
        app = relaunch(app, session: session)
        openSettings(in: app)
        XCTAssertEqual(archiveSwitch(in: app).value as? String, "0", "Off didn't stick")
        XCTAssertFalse(timeRow("After", in: app).isEnabled, "the time is enabled with archiving off")

        setSwitch(archiveSwitch(in: app), on: true)
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.timeRow("After", in: app).isEnabled }, "the time stayed dimmed with archiving on")
        XCTAssertEqual(time(of: timeRow("After", in: app)), "24 Hours", "the time didn't come back")
        withExtendedLifetime(server) {}
    }

    /// Arc's four times are offered (Off is the switch, not a time here); 7 Days sticks.
    func testSevenDaysStaysAfterRelaunch() throws {
        let server = try FixtureServer(html: Self.page)
        let session = UUID().uuidString
        var app = launch(session: session, server: server)
        openSettings(in: app)
        choose("7 Days", from: timeRow("After", in: app), offering: ["12 Hours", "24 Hours", "7 Days", "30 Days"],
               notOffering: ["Off"], in: app)
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.time(of: self.timeRow("After", in: app)) == "7 Days" }, "the time didn't change")

        closeSettings(in: app)
        app = relaunch(app, session: session)
        openSettings(in: app)
        XCTAssertEqual(time(of: timeRow("After", in: app)), "7 Days", "the time didn't stick")
        withExtendedLifetime(server) {}
    }

    /// With archiving off, a tab idle two days is still open at the next launch; turned back on, the
    /// note says it will move, and at the next launch it has.
    func testOffKeepsAnIdleTab() throws {
        let server = try FixtureServer(html: Self.page)
        let session = UUID().uuidString
        var app = launch(session: session, server: server)
        let field = app.textFields["Search or enter address"]
        app.buttons["NewTabPill"].tap()
        XCTAssertTrue(field.appears(within: Ceiling.ui), "+ didn't open the search panel")
        field.typeText(server.url.appending(path: "b").absoluteString + "\n")
        XCTAssertTrue(heading("/b", in: app).appears(within: Ceiling.load), "the second tab didn't load")
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui))

        openSettings(in: app)
        setSwitch(archiveSwitch(in: app), on: false)
        closeSettings(in: app)

        // /a, in the background, was last looked at two days ago. The archiver runs as the tabs load,
        // before the tab button shows their count.
        app = relaunch(app, session: session, idleFor: Self.twoDays)
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.launch), "Off archived the idle tab")

        openSettings(in: app)
        setSwitch(archiveSwitch(in: app), on: true)
        XCTAssertTrue(footer(containing: "1 tab has been idle longer than that, and will move the next time you come back to Cormorant.",
                             in: app).appears(within: Ceiling.ui), "no note about the idle tab")
        closeSettings(in: app)

        app = relaunch(app, session: session, idleFor: Self.twoDays)
        XCTAssertTrue(app.buttons["Tabs, 1 open"].appears(within: Ceiling.launch), "the idle tab didn't archive once on")
        withExtendedLifetime(server) {}
    }

    /// Off turns every Space off at once; on gives each its own time back, Off included, and a time
    /// this build doesn't offer (Trips' 3 days) too.
    func testSeveralSpacesTurnOffTogetherAndComeBackAsTheyWere() throws {
        let server = try FixtureServer(html: Self.page)
        let session = UUID().uuidString
        let spaces = ["-uiTestingArchiveSpaces", "Work:43200,Reading:off,Trips:259200"]
        var app = launch(session: session, server: server, extra: spaces)
        openSettings(in: app)
        let times = timeRow("Time per Space", in: app)
        XCTAssertTrue(times.appears(within: Ceiling.ui), "no times by Space")
        XCTAssertEqual(time(of: times), "Varies")
        XCTAssertTrue(footer(containing: "Spaces never archive on their own.", in: app).exists)
        assertTimes(["Home": "24 Hours", "Work": "12 Hours", "Reading": "Off", "Trips": "3 Days"], in: app)

        setSwitch(archiveSwitch(in: app), on: false)
        XCTAssertTrue(waitUntil(Ceiling.ui) { !times.isEnabled }, "times by Space still enabled with archiving off")
        XCTAssertEqual(time(of: times), "Varies", "the times that come back changed")
        XCTAssertTrue(footer(containing: "Tabs in every Space stay open until you close them.", in: app).exists)

        closeSettings(in: app)
        app = relaunch(app, session: session, extra: spaces)
        openSettings(in: app)
        XCTAssertEqual(archiveSwitch(in: app).value as? String, "0", "Off didn't stick")

        setSwitch(archiveSwitch(in: app), on: true)
        XCTAssertTrue(waitUntil(Ceiling.ui) { self.timeRow("Time per Space", in: app).isEnabled },
                      "times by Space stayed dimmed with archiving on")
        assertTimes(["Home": "24 Hours", "Work": "12 Hours", "Reading": "Off", "Trips": "3 Days"], in: app)
        withExtendedLifetime(server) {}
    }

    // MARK: Helpers

    /// Launches and opens the fixture's /a in a tab. `session` keeps tabs and settings across
    /// relaunches. With a page open, a relaunch comes back to it rather than to the search panel, which
    /// hides the bar and can come up again just after a test closes it.
    private func launch(session: String, server: FixtureServer, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + extra
        app.launchEnvironment["CORMORANT_UI_TESTING_SESSION"] = session
        app.launch()
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        field.typeText(server.url.appending(path: "a").absoluteString + "\n")
        // Generous: the first page load on a fresh simulator is slow.
        XCTAssertTrue(heading("/a", in: app).appears(within: Ceiling.load), "fixture page didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
        return app
    }

    /// Once everything is on disk, kills the app and launches it again with its tabs; `idleFor` (seconds)
    /// makes every tab last looked at that long ago.
    private func relaunch(_ app: XCUIApplication, session: String, extra: [String] = [],
                          idleFor: String? = nil) -> XCUIApplication {
        XCTAssertTrue(app.savesSettle(), "saves didn't land")
        app.terminate()
        let next = XCUIApplication()
        next.launchArguments = ["-uiTesting"] + extra + (idleFor.map { ["-uiTestingIdleFor", $0] } ?? [])
        next.launchEnvironment["CORMORANT_UI_TESTING_SESSION"] = session
        next.launch()
        XCTAssertTrue(next.buttons["Page actions"].appears(within: Ceiling.launch), "the app didn't relaunch")
        return next
    }

    private func openSettings(in app: XCUIApplication) {
        // The bar slides down with the keyboard after the search panel closes; a tap while it moves is dropped.
        app.buttons["Page actions"].tapWhenSettled()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.appears(within: Ceiling.ui), "caret sheet didn't open")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].appears(within: Ceiling.ui), "Settings didn't open")
        XCTAssertTrue(archiveSwitch(in: app).appears(within: Ceiling.ui), "no Archive Idle Tabs switch")
    }

    /// Closes Settings, then swipes the caret sheet away by its grabber, back to the browser.
    private func closeSettings(in app: XCUIApplication) {
        let done = app.navigationBars["Settings"].buttons["Done"]
        done.tapWhenSettled()
        XCTAssertTrue(done.disappears(within: Ceiling.ui), "Settings didn't close")
        let grabber = app.descendants(matching: .any)["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.appears(within: Ceiling.ui))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.buttons["Settings"].disappears(within: Ceiling.ui), "caret sheet didn't close")
    }

    /// A row showing a time, which reads "<title>, <time>".
    private func timeRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
    }

    private func time(of row: XCUIElement) -> String? {
        guard row.exists, let comma = row.label.range(of: ", ") else { return nil }
        return String(row.label[comma.upperBound...])
    }

    private func archiveSwitch(in app: XCUIApplication) -> XCUIElement {
        app.switches["Archive Idle Tabs"]
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard (toggle.value as? String == "1") != on else { return }
        // The switch itself, not the row's label, once Settings has stopped sliding up (a tap on a
        // sheet still moving landed where the switch had been).
        let target = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        target.tapWhenSettled()
        XCTAssertTrue(waitUntil(Ceiling.ui) { toggle.value as? String == (on ? "1" : "0") },
                      "the switch didn't turn \(on ? "on" : "off")", file: file, line: line)
    }

    private func footer(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func heading(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts["Path \(path)"].firstMatch
    }

    /// Opens Time per Space, checks each Space's time, and comes back.
    private func assertTimes(_ expected: [String: String], in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        timeRow("Time per Space", in: app).tap()
        let title = app.navigationBars["Archive Idle Tabs"]
        XCTAssertTrue(title.appears(within: Ceiling.ui), "Time per Space didn't open", file: file, line: line)
        for (space, time) in expected {
            let row = timeRow(space, in: app)
            XCTAssertTrue(row.appears(within: Ceiling.ui), "no row for \(space)", file: file, line: line)
            XCTAssertEqual(self.time(of: row), time, "\(space)'s time", file: file, line: line)
        }
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].appears(within: Ceiling.ui), "didn't come back to Settings",
                      file: file, line: line)
    }

    /// Picks `item` from `menu`'s menu, after checking it holds `offering` and none of `notOffering`. A
    /// synthesized tap doesn't activate menu items on the iOS 27 simulator (the menu stays up), so press
    /// the item and lift on it, as a finger can.
    private func choose(_ item: String, from menu: XCUIElement, offering: [String] = [], notOffering: [String] = [],
                        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Settings may still be sliding up: a tap on a moving sheet lands where the row had been.
        menu.tapWhenSettled()
        func choice(_ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        let target = choice(item)
        XCTAssertTrue(target.appears(within: Ceiling.ui), "the menu didn't open", file: file, line: line)
        XCTAssertTrue(waitUntil(Ceiling.ui) { target.isHittable }, "the menu didn't settle", file: file, line: line)
        for label in offering { XCTAssertTrue(choice(label).exists, "the menu doesn't offer \(label)", file: file, line: line) }
        for label in notOffering { XCTAssertFalse(choice(label).exists, "the menu offers \(label)", file: file, line: line) }
        target.settledFrame()
        target.press(forDuration: 0.3, thenDragTo: target)
        XCTAssertTrue(target.disappears(within: Ceiling.ui), "menu didn't close", file: file, line: line)
    }
}
