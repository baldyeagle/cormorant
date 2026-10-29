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

    /// Taps once the element has stopped moving: a tap on a switcher or menu that's still
    /// presenting is dropped.
    func tapWhenSettled() {
        settledFrame()
        tap()
    }

    /// Taps a control in a sheet that just started presenting, once it has slid in. A tap meanwhile is
    /// dropped, and neither `settledFrame()` nor `isHittable` can tell: on the iOS 27.1 simulator a
    /// sheet's elements report their final frames from the start of the slide.
    func tapInPresentedSheet() {
        Thread.sleep(forTimeInterval: 0.75)
        tap()
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
