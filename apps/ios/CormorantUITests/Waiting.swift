import XCTest

/// Waits that check at once, then back off. XCTest's `waitForExistence`, `waitForNonExistence` and
/// predicate expectations first check about a second in, so a wait on an element already on screen
/// still cost a second, and those seconds were a third of the suite's run time. Use these instead.
@MainActor
extension XCUIElement {
    /// True as soon as the element exists; false if it doesn't within `timeout`.
    func appears(within timeout: TimeInterval) -> Bool {
        waitUntil(timeout, "Waiting \(timeout)s for \(description) to exist") { exists }
    }

    /// True as soon as the element is gone; false if it's still there after `timeout`.
    func disappears(within timeout: TimeInterval) -> Bool {
        waitUntil(timeout, "Waiting \(timeout)s for \(description) to not exist") { !exists }
    }

    /// The element's frame once two checks 0.15 s apart agree, or its last frame after `timeout`.
    /// Use before tapping or measuring something that animates in: a menu item is hittable while it's
    /// still springing open (when UIKit takes a tap as a dismissal), and a page that just appeared
    /// may still be sliding into place.
    @discardableResult
    func settledFrame(within timeout: TimeInterval = 3) -> CGRect {
        XCTContext.runActivity(named: "Waiting for \(description) to stop moving") { _ in
            let deadline = Date.now + timeout
            var frame = self.frame
            while Date.now < deadline {
                RunLoop.current.run(until: .now + 0.15)
                let now = self.frame
                if now == frame { break }
                frame = now
            }
            return frame
        }
    }

    /// Taps once the element has stopped moving. For when XCTest's own animation wait can't help: a
    /// context menu's items (the wait is off while a menu is up), or a bar moved by the keyboard
    /// (another process's animation).
    func tapWhenSettled() {
        settledFrame()
        tap()
    }

}

/// Ceilings for waits on something that should happen, by what's being waited for. A ceiling only
/// matters when a test is about to fail, so each is far above the slowest CI runner seen (a 3-core
/// runner's first page load took up to 22 s; a single query, up to 10 s), not near typical times:
/// a test passes the moment its condition holds. Checks that something *stays* for N seconds keep
/// their own N.
enum Ceiling {
    /// The app launching, or relaunching with its saved tabs, to its first screen.
    static let launch: TimeInterval = 60
    /// Anything that needs a page to load: a tab's page, a preview's, a reload, a switcher snapshot.
    static let load: TimeInterval = 60
    /// The app's own UI answering an action: a menu, sheet, tab count, focus or scroll.
    static let ui: TimeInterval = 20
}

@MainActor
extension XCUIApplication {
    /// True once the app reports (`UITestingProbes`, `-uiTesting` only) that everything it writes
    /// while browsing is on disk, so a test that kills it knows what the relaunch should find.
    func savesSettle() -> Bool {
        let probe = descendants(matching: .any)["UITesting.saves"].firstMatch
        return waitUntil(Ceiling.ui, "Waiting for the app's saves to land") { probe.value as? String == "settled" }
    }

    /// Whether XCTest waits for the app's animations to finish before each action (its default), so a
    /// tap never lands mid-transition, where UIKit drops it. Off only while a link context menu is up:
    /// on the iOS 27.1 simulator one never reports its animations finished, and every query waited out
    /// a 60-second timeout. Private API; always true, and setting it a no-op, if XCTest drops it.
    var waitsForAnimations: Bool {
        get {
            guard responds(to: NSSelectorFromString("idleAnimationWaitEnabled")) else { return true }
            return value(forKey: "idleAnimationWaitEnabled") as? Bool ?? true
        }
        set {
            guard responds(to: NSSelectorFromString("setIdleAnimationWaitEnabled:")) else { return }
            setValue(newValue, forKey: "idleAnimationWaitEnabled")
        }
    }
}

/// Checks `condition` at once, then after 0.1, 0.2, 0.4 and 0.8 s, then every second (XCTest's own
/// rate), until it holds or `timeout` passes, and returns its last value. `name` titles the activity
/// in the test report.
///
/// No faster than XCTest once a wait has gone on: every check makes the app snapshot its
/// accessibility tree, web content included, which slows the page load or animation being waited
/// for. On 3-core CI runners, checks every 0.1 s made taps' p90 go from 1.9 s to 7.1 s, and every
/// 0.5 s still took first page loads from ~5 s to 10-22 s.
@MainActor
func waitUntil(_ timeout: TimeInterval, _ name: String = "Waiting for a condition",
               _ condition: () -> Bool) -> Bool {
    XCTContext.runActivity(named: name) { _ in
        let deadline = Date.now + timeout
        var interval: TimeInterval = 0.1
        while !condition() {
            guard Date.now < deadline else { return condition() }
            RunLoop.current.run(until: min(.now + interval, deadline))
            interval = min(interval * 2, 1)
        }
        return true
    }
}
