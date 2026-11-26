import CormorantTestSupport
import XCTest

/// Folders end to end: a card's menu puts its tab in a new folder, which shows among the cards as a
/// stack; tapping it shows the folder's cards under an All Tabs pill, which goes back. What folders do
/// (joining, leaving, pinning, archiving, closing) is CormorantKit's FolderTests.
@MainActor
final class FolderTests: UITestCase {
    private static let page = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <title>Trip Plans</title>
        <h1>Plans</h1>
        """

    func testNewFolderFromACardThenOpenItAndGoBack() throws {
        let server = try FixtureServer(html: Self.page)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingOpen", server.url.appending(path: "plans").absoluteString]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Plans"].firstMatch.appears(within: Ceiling.load), "the page didn't load")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch.tapWhenSettled()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'TabCard' AND label == 'Trip Plans'")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for the tab")

        // The card's menu, then Add to Folder's New Folder…. A context menu's items are cells, and
        // a synthesized tap doesn't choose one on the iOS 27 simulator: each is pressed and lifted on.
        // A context menu up never reports its animations finished: XCTest's animation wait is off
        // until it has closed.
        let addToFolder = menuItem("Add to Folder", in: app)
        let frame = card.settledFrame()
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        app.motionSettles()
        app.waitsForAnimations = false
        var opened = false
        for _ in 1...3 where !opened {
            center.press(forDuration: 1.2)
            opened = addToFolder.appears(within: Ceiling.ui) && waitUntil(Ceiling.ui) { addToFolder.isHittable }
        }
        XCTAssertTrue(opened, "the card's menu didn't open")
        choose(addToFolder)
        let newFolder = menuItem("New Folder…", in: app)
        XCTAssertTrue(newFolder.appears(within: Ceiling.ui), "no New Folder… in Add to Folder")
        choose(newFolder)

        // Created with the name it offers: typing in an alert's field on the simulator sometimes went
        // nowhere, the software keyboard never coming up. Names are CormorantKit's FolderTests.
        let name = app.alerts["New Folder"].textFields.firstMatch
        XCTAssertTrue(name.appears(within: Ceiling.ui), "New Folder didn't ask for a name")
        app.waitsForAnimations = true
        let create = app.alerts["New Folder"].buttons["Create"]
        create.tapWhenSettled()
        XCTAssertTrue(create.disappears(within: Ceiling.ui), "the New Folder alert stayed after Create")

        // The stack in the card's place.
        let folder = app.descendants(matching: .any).matching(identifier: "FolderCard").firstMatch
        XCTAssertTrue(folder.appears(within: Ceiling.ui), "no folder among the cards")
        XCTAssertEqual(folder.label, "New Folder")
        XCTAssertEqual(folder.value as? String, "1 tab")
        XCTAssertTrue(card.disappears(within: Ceiling.ui), "the tab's card is still among the cards")

        // Into it, and back.
        folder.tapWhenSettled()
        let pill = app.descendants(matching: .any).matching(identifier: "FolderBackPill").firstMatch
        XCTAssertTrue(pill.appears(within: Ceiling.ui), "no All Tabs pill in the folder")
        XCTAssertTrue(card.appears(within: Ceiling.ui), "the folder doesn't show its tab's card")
        XCTAssertTrue(folder.disappears(within: Ceiling.ui), "the folder's stack still shows inside it")
        pill.tapWhenSettled()
        XCTAssertTrue(folder.appears(within: Ceiling.ui), "All Tabs didn't go back to the stack")
        XCTAssertTrue(pill.disappears(within: Ceiling.ui), "the pill stayed after going back")
        withExtendedLifetime(server) {}
    }

    private func menuItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
            .matching(NSPredicate(format: "elementType == %d OR elementType == %d",
                                  XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue))
            .firstMatch
    }

    private func choose(_ item: XCUIElement) {
        XCTAssertTrue(waitUntil(Ceiling.ui) { item.isHittable }, "\(item.description) isn't hittable")
        item.settledFrame()
        item.press(forDuration: 0.3, thenDragTo: item)
    }
}
