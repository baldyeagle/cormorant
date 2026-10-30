import XCTest

/// Base for the UI tests: stops at the first failure, and attaches what was on screen to it. CI runs
/// with `-collect-test-diagnostics never` (no screen recording), so this is all a failed run has to
/// show what the app was doing.
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
