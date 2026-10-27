import XCTest

/// Base for the UI tests: stops at the first failure, and attaches what was on screen to it. CI turns
/// off XCTest's own screen capture (no recording, no automatic screenshots), so this is all a failed
/// run has to show what the app was doing.
@MainActor
class UITestCase: XCTestCase {
    /// Main thread only (`record` checks).
    nonisolated(unsafe) private var attaching = false

    override func setUp() {
        super.setUp()
        // Stop at the first failure: what follows would only wait out its ceilings, or 60 s per
        // query if a link menu was left up with the animation wait off.
        continueAfterFailure = false
    }

    /// XCTest's own isolation: not the main actor's.
    nonisolated override func record(_ issue: XCTIssue) {
        guard Thread.isMainThread else { return super.record(issue) }
        // An issue raised while attaching (the app hung or gone) is dropped: with
        // `continueAfterFailure` off, recording it would stop the test before the issue it's
        // attaching to is recorded.
        guard !attaching else { return }
        attaching = true
        nonisolated(unsafe) var issue = issue
        MainActor.assumeIsolated { Self.attachScreen(to: &issue) }
        attaching = false
        super.record(issue)
    }

    /// For fixture pages with links to long-press: reports the page's text selection as a paragraph
    /// reading "Selected: <text>", which `pressForLinkMenu` looks for. Goes at the end of the page.
    static let selectionReport = """
        <p id="selection"></p>
        <script>
        document.addEventListener('selectionchange', () => {
            const text = String(getSelection())
            document.getElementById('selection').textContent = text ? 'Selected: ' + text : ''
        })
        </script>
        """

    /// Long-presses `link` until `item`, one of its context menu's items, appears; false if it doesn't.
    /// Leaves XCTest's animation wait off (see `XCUIApplication.waitsForAnimations`) for the caller to
    /// turn back on once the menu has closed.
    ///
    /// WebKit asks the page's process what's under the finger, and when the answer comes late (a
    /// loaded CI runner took 4 s just to deliver a press) it takes the press as one on text and
    /// selects a word instead. Only then, as the page reports (`selectionReport`), it clears the
    /// selection by tapping the page's "Path" heading and presses again, up to three presses in all.
    /// No menu and no selection fails at once.
    func pressForLinkMenu(_ link: XCUIElement, until item: XCUIElement, in app: XCUIApplication) -> Bool {
        app.waitsForAnimations = false
        let selected = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Selected: '"))
            .firstMatch
        for attempt in 1...3 {
            link.press(forDuration: 1.5)
            if item.appears(within: Ceiling.ui) { return true }
            guard attempt < 3, selected.exists else { return false }
            let cleared = XCTContext.runActivity(named: "WebKit selected text instead (\(selected.label))") { _ in
                app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Path '")).firstMatch.tap()
                return selected.disappears(within: Ceiling.ui)
            }
            guard cleared else { return false }
        }
        return false
    }

    /// Taps the link menu's preview card, once it has stopped growing. The page inside isn't hittable,
    /// and its elements report where the preview's view is kept, not where the card draws it.
    func tapLinkPreview(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.otherElements.matching(NSPredicate(format: "label == 'Preview'")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no preview card", file: file, line: line)
        let frame = card.settledFrame()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    private static func attachScreen(to issue: inout XCTIssue) {
        issue.add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        let app = XCUIApplication()
        guard app.state == .runningForeground else { return }
        // A link menu may be up, which never reports its animations finished.
        app.waitsForAnimations = false
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Accessibility tree"
        issue.add(tree)
    }
}
