import XCTest

/// Settings shows whether Cormorant is the default browser and offers a way to Default Apps.
@MainActor
final class DefaultBrowserSettingsTests: UITestCase {
    func testSettingsShowsDefaultBrowserSection() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.appears(within: Ceiling.launch), "no search panel at launch")
        app.buttons["Close search"].firstMatch.tap()
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close")

        // The bar slides down with the keyboard after the search panel closes; a tap while it moves is dropped.
        app.buttons["Page actions"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Settings"].appears(within: Ceiling.ui), "caret sheet didn't open")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].appears(within: Ceiling.ui), "Settings didn't open")

        // `-uiTesting` never asks the system, so the status is never "Default Browser": the text is
        // the section header, and the button is the not-default one.
        XCTAssertTrue(app.staticTexts["Default Browser"].appears(within: Ceiling.ui), "no Default Browser section")
        XCTAssertTrue(app.buttons["Make Default Browser…"].exists, "no button to Default Apps")
    }
}
