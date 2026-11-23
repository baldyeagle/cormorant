import CormorantTestSupport
import XCTest

/// Pinned tabs end to end: the caret sheet's Pin tile pins the tab on screen with a toast, the
/// switcher shows it as a tile above the cards, and the tile's menu unpins it back into a card.
/// What pins do (closing one, Back to Pinned Page, a relaunch, a new tab's tiles) is CormorantTests'
/// PinsTests.
@MainActor
final class PinnedTabsTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Mail</title>
        <h1 id="path">Path</h1>
        <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
        """

    func testPinFromCaretSheetThenUnpinFromTheSwitcher() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingOpen", server.url.appending(path: "mail").absoluteString]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Path /mail"].firstMatch.appears(within: Ceiling.load), "the page didn't load")

        app.buttons["Page actions"].tapWhenSettled()
        let pin = app.buttons["PinTile"]
        XCTAssertTrue(pin.appears(within: Ceiling.ui), "no Pin tile in the caret sheet")
        XCTAssertEqual(pin.label, "Pin")
        pin.tapWhenSettled()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pinned'")).firstMatch
        XCTAssertTrue(toast.appears(within: Ceiling.ui), "no toast after pinning")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch.tapWhenSettled()
        let tile = app.buttons.matching(identifier: "PinnedTab").firstMatch
        XCTAssertTrue(tile.appears(within: Ceiling.ui), "no pinned tile in the switcher")
        XCTAssertEqual(tile.label, "Mail")
        XCTAssertFalse(app.buttons["Close Mail"].exists, "the pinned tab is a card too")

        // Its menu: pressed open, then Unpin pressed and lifted on (a synthesized tap doesn't choose a
        // menu item on the iOS 27 simulator). A context menu up never reports its animations finished,
        // as the link menu's doesn't: XCTest's animation wait is off until it has closed.
        app.waitsForAnimations = false
        let unpin = app.buttons["Unpin"]
        var opened = false
        for _ in 1...3 where !opened {
            tile.settledFrame()
            tile.press(forDuration: 1.2)
            opened = unpin.appears(within: Ceiling.ui) && waitUntil(Ceiling.ui) { unpin.isHittable }
        }
        XCTAssertTrue(opened, "the tile's menu didn't open")
        XCTAssertTrue(app.buttons["Rename…"].exists, "no Rename in the tile's menu")
        unpin.settledFrame()
        unpin.press(forDuration: 0.3, thenDragTo: unpin)
        XCTAssertTrue(tile.disappears(within: Ceiling.ui), "the tile stayed after Unpin")
        app.waitsForAnimations = true
        let toastAfter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Unpinned'")).firstMatch
        XCTAssertTrue(toastAfter.appears(within: Ceiling.ui), "no toast after unpinning")
        withExtendedLifetime(server) {}
    }
}
