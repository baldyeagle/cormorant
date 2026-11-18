import CormorantTestSupport
import XCTest

/// What only the screen shows of downloads, end to end; which links download, where files land,
/// names, and what passes, calendar files and AR models do are CormorantTests' DownloadsTests.
@MainActor
final class DownloadsTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Fixture</title>
        <style>a { display: block; font-size: 24px; padding: 14px 0; }</style>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        <a href="/files/notes">Attached notes</a>
        <a href="/series.ics">Two events</a>
        """

    private static let files: [String: FixtureServer.File] = [
        "/series.ics": .init(contentType: "text/calendar; charset=utf-8", body: Data("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Planning
            DTSTART:20261202T150000Z
            END:VEVENT
            BEGIN:VEVENT
            SUMMARY:Retro
            DTSTART;VALUE=DATE:20261203
            END:VEVENT
            END:VCALENDAR
            """.utf8)),
        "/files/notes": .init(contentType: "text/plain; charset=utf-8", body: Data("Hello from the notes".utf8),
                              headers: ["Content-Disposition": "attachment; filename=\"Meeting notes.txt\""]),
    ]

    /// The caret sheet lists a download under Downloads, and tapping it there shows it in Quick Look.
    /// (Its toasts come and go on a timer, so they're checked in-process.)
    func testDownloadIsListedAndOpensInQuickLook() throws {
        let server = try FixtureServer(html: Self.page, files: Self.files)
        let app = launchOnPage(server.url)

        app.webViews.links["Attached notes"].tapWhenSettled()

        app.buttons["Page actions"].tapWhenSettled()
        // Shows once a download is listed, while the sheet is up too.
        let row = app.buttons["DownloadsRow"]
        XCTAssertTrue(row.appears(within: Ceiling.load), "no Downloads row in the caret sheet; \(server.requestLog)")
        row.tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Downloads"].appears(within: Ceiling.ui), "Downloads didn't open")
        let download = app.descendants(matching: .any)["Download.Meeting notes.txt"].firstMatch
        XCTAssertTrue(download.appears(within: Ceiling.ui), "the download isn't listed")
        download.tapWhenSettled()

        let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Hello from the notes'")).firstMatch
        XCTAssertTrue(text.appears(within: Ceiling.load), "Quick Look didn't show the file")
        withExtendedLifetime(server) {}
    }

    /// A calendar file's events are listed; one opens the system's New Event editor, filled in, and
    /// cancelling it comes back to the list.
    func testCalendarFileListsItsEventsAndOpensTheEditor() throws {
        let server = try FixtureServer(html: Self.page, files: Self.files)
        let app = launchOnPage(server.url)

        app.webViews.links["Two events"].tapWhenSettled()

        XCTAssertTrue(app.navigationBars["2 Events"].appears(within: Ceiling.load), "no event list; \(server.requestLog)")
        let retro = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Retro'")).firstMatch
        XCTAssertTrue(retro.appears(within: Ceiling.ui), "Retro isn't listed")
        retro.tapWhenSettled()
        XCTAssertTrue(app.navigationBars["New Event"].appears(within: Ceiling.ui), "the editor didn't open")
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Retro'")).firstMatch
        XCTAssertTrue(title.appears(within: Ceiling.ui), "the editor isn't filled in with the event")
        // The editor runs in another process: its Cancel isn't under its navigation bar in the tree.
        app.buttons["Cancel"].firstMatch.tapWhenSettled()
        XCTAssertTrue(app.navigationBars["New Event"].disappears(within: Ceiling.ui), "the editor didn't close")
        XCTAssertTrue(app.navigationBars["2 Events"].exists, "the list went with it")
        withExtendedLifetime(server) {}
    }

    private func launchOnPage(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        // On the page from the start (`-uiTestingOpen`): no typing, no keyboard to wait out.
        app.launchArguments = ["-uiTesting", "-uiTestingOpen", url.absoluteString]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Path /"].firstMatch.appears(within: Ceiling.load), "fixture page didn't load")
        return app
    }
}
