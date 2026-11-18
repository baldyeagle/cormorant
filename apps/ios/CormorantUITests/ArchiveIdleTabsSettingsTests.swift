import CormorantTestSupport
import XCTest

/// Settings' Archive Idle Tabs on screen: the switch is wired to the setting and the time row dims with
/// it. What the setting does (every Space at once, each time back, idle tabs kept or archived across a
/// relaunch) and what the footer says are CormorantTests' `ArchiveIdleTabsTests`.
@MainActor
final class ArchiveIdleTabsSettingsTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        """

    func testSwitchTurnsArchivingOffAndDimsTheTime() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingOpen", server.url.appending(path: "a").absoluteString]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Path /a"].appears(within: Ceiling.load), "fixture page didn't load")

        app.buttons["Page actions"].tapWhenSettled()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.appears(within: Ceiling.ui), "caret sheet didn't open")
        settings.tapWhenSettled()
        let toggle = app.switches["Archive Idle Tabs"]
        XCTAssertTrue(toggle.appears(within: Ceiling.ui), "no Archive Idle Tabs switch")
        let after = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'After, '")).firstMatch
        XCTAssertTrue(after.appears(within: Ceiling.ui), "no time row")
        XCTAssertEqual(toggle.value as? String, "1", "auto-archive isn't on by default")
        XCTAssertEqual(after.label, "After, 24 Hours")
        XCTAssertTrue(after.isEnabled)

        // The switch itself, not the row's label.
        let target = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        target.tapWhenSettled()
        XCTAssertTrue(waitUntil(Ceiling.ui) { toggle.value as? String == "0" }, "the switch didn't turn off")
        // Dimmed, still showing the time that comes back.
        XCTAssertTrue(waitUntil(Ceiling.ui) { !after.isEnabled }, "the time is still enabled with archiving off")
        XCTAssertEqual(after.label, "After, 24 Hours")

        target.tapWhenSettled()
        XCTAssertTrue(waitUntil(Ceiling.ui) { toggle.value as? String == "1" }, "the switch didn't turn back on")
        XCTAssertTrue(waitUntil(Ceiling.ui) { after.isEnabled }, "the time stayed dimmed with archiving on")
        withExtendedLifetime(server) {}
    }
}
