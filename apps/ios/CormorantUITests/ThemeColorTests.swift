import UIKit
import XCTest

/// Site-tinted chrome: the status-bar strip and the bottom bar take a page's theme color, per tab,
/// with a foreground that reads on it, and go back to the default chrome without one.
/// Colors are read from screenshots.
@MainActor
final class ThemeColorTests: XCTestCase {
    private static let red = Pixel(hex: 0xB91C1C)
    private static let yellow = Pixel(hex: 0xFDE047)
    private static let navy = Pixel(hex: 0x1E3A8A)
    /// The default chrome (the launch background).
    private static let lightDefault = Pixel(hex: 0xFFFFFF)
    private static let darkDefault = Pixel(hex: 0x030712)

    private static func page(title: String, head: String = "", body: String = "") -> String {
        """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        \(head)
        <title>\(title)</title>
        <h1>\(title)</h1>
        <p>Body text for \(title).</p>
        \(body)
        """
    }

    private static let redPage = page(title: "Red page", head: ##"<meta name="theme-color" content="#b91c1c">"##)
    private static let plainPage = page(title: "Plain page")
    /// Light-only, like many sites: white theme color and background whatever the system appearance.
    private static let whitePage = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="theme-color" content="#ffffff">
        <title>White page</title>
        <h1>White page</h1>
        <p>Body text for White page.</p>
        """
    /// Red, long enough to pull, and counting its loads in `sessionStorage` (it survives a reload).
    private static let refreshPage = page(title: "Refresh page", head: ##"""
        <meta name="theme-color" content="#b91c1c">
        <script>
          sessionStorage.loads = Number(sessionStorage.loads || 0) + 1;
          addEventListener("DOMContentLoaded", () => {
            document.getElementById("count").textContent = "Load " + sessionStorage.loads;
          });
        </script>
        """##, body: #"<p id="count">Loading</p>"# + longBody)
    /// No theme color, but a background of its own.
    private static let sandPage = page(title: "Sand page", head: "<style>html, body { background: #fde68a }</style>")
    /// Mid-tone tints, where the two foregrounds come closest, over page content of the other extreme.
    private static let bluePage = page(title: "Blue page", head: ##"<meta name="theme-color" content="#2563eb">"##, body: longBody)
    private static let skyPage = page(title: "Sky page", head: ##"""
        <meta name="theme-color" content="#3b82f6">
        <style>html, body { background: #000; color: #fff }</style>
        """##, body: longBody)
    /// Enough to scroll, so the bar can collapse.
    private static let longBody = String(repeating: "<p>Filler text under the bar, line after line.</p>", count: 80)
    private static let schemePage = page(title: "Scheme page", head: """
        <meta name="theme-color" media="(prefers-color-scheme: light)" content="#fde047">
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#1e3a8a">
        """)

    func testThemeColorTintsChromeAndResetsOnAPageWithout() throws {
        let red = try FixtureServer(html: Self.redPage)
        let plain = try FixtureServer(html: Self.plainPage)
        let app = launch()

        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        // Same tab, next page: no theme color, so back to the default.
        navigate(to: plain.url, in: app, expecting: "Plain page")
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)
        withExtendedLifetime([red, plain]) {}
    }

    func testTintIsPerTab() throws {
        let red = try FixtureServer(html: Self.redPage)
        let plain = try FixtureServer(html: Self.plainPage)
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        // A new tab on a page without a theme color.
        app.buttons["Tabs, 1 open"].tap()
        let newTab = app.buttons["New Tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.tap()
        open(plain.url, in: app, expecting: "Plain page")
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)

        // Back to the red tab.
        app.buttons["Tabs, 2 open"].tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Red page'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card for the red tab")
        card.tap()
        XCTAssertTrue(app.webViews.staticTexts["Body text for Red page."].waitForExistence(timeout: 10))
        assertChrome(in: app, strip: Self.red, foreground: .light)

        // Closing every tab leaves the empty state, in the default colors. It has no web view to
        // find the strip by, so measure it now.
        let strip = Shot.statusStripRegion(app: app)
        app.buttons["Tabs, 2 open"].tap()
        for remaining in [2, 1] {
            // Cards overlap and scroll; close whichever one is on screen.
            let closes = app.buttons.matching(identifier: "xmark.circle.fill")
            XCTAssertTrue(closes.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(closes.count, remaining)
            let close = closes.allElementsBoundByIndex.first { app.frame.contains($0.frame) }
            XCTAssertNotNil(close, "no close button on screen")
            close?.tap()
        }
        XCTAssertTrue(app.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(searchField(in: app).waitForExistence(timeout: 5))
        if #available(iOS 27, *) { assertStrip(in: app, is: Self.lightDefault, region: strip) }
        assertStatusBar(in: app, foreground: .dark, region: strip)
        withExtendedLifetime([red, plain]) {}
    }

    /// WebKit resolves `media="(prefers-color-scheme: …)"`; the chrome takes the variant for the appearance.
    func testThemeColorFollowsColorScheme() throws {
        let server = try FixtureServer(html: Self.schemePage)
        var app = launch(appearance: "light")
        open(server.url, in: app, expecting: "Scheme page")
        assertChrome(in: app, strip: Self.yellow, foreground: .dark)
        app.terminate()

        app = launch(appearance: "dark")
        open(server.url, in: app, expecting: "Scheme page")
        assertChrome(in: app, strip: Self.navy, foreground: .light)
        withExtendedLifetime(server) {}
    }

    /// Pull to refresh on a tinted page: the reload goes through, and the tint holds through it
    /// (WebKit's interim colors during the reload never reach the chrome).
    func testPullToRefreshKeepsTint() throws {
        let server = try FixtureServer(html: Self.refreshPage)
        let app = launch()
        open(server.url, in: app, expecting: "Refresh page")
        XCTAssertTrue(app.webViews.staticTexts["Load 1"].waitForExistence(timeout: 5))
        assertChrome(in: app, strip: Self.red, foreground: .light)

        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.webViews.staticTexts["Load 2"].waitForExistence(timeout: 10), "pull didn't reload")
        assertChrome(in: app, strip: Self.red, foreground: .light)
        // The pull mustn't have left the bar collapsed.
        XCTAssertTrue(app.buttons["Address"].exists, "bar collapsed after the pull")
        withExtendedLifetime(server) {}
    }

    /// A link opened from the long-press menu: neither its preview (a separate web view) nor a
    /// background tab for it changes this tab's tint; switching to that tab does.
    func testLinkMenuBackgroundTabKeepsTintUntilShown() throws {
        let blue = try FixtureServer(html: Self.bluePage)
        let red = try FixtureServer(html: Self.page(
            title: "Red page", head: ##"<meta name="theme-color" content="#b91c1c">"##,
            body: #"<a href="\#(blue.url.absoluteString)" style="display: block; font-size: 24px">Blue link</a>"#))
        let app = launch(waitsForIdleAnimations: false)
        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        let link = app.webViews.links["Blue link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.press(forDuration: 1.5)
        let item = app.buttons["Open in Background Tab"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no link menu")
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: item)], timeout: 5)
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "menu didn't close")
        XCTAssertTrue(app.buttons["Tabs, 2 open"].waitForExistence(timeout: 5), "no background tab")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        app.buttons["Tabs, 2 open"].tap()
        // A background tab has no title until it's shown, so its card reads as the host. It sits
        // behind the current tab's card, mostly off screen: tap the sliver that shows.
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close, 127.0.0.1'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no card for the background tab")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: max(card.frame.minX, 0) + 20, dy: card.frame.midY)).tap()
        XCTAssertTrue(app.webViews.staticTexts["Body text for Blue page."].waitForExistence(timeout: 10))
        assertChrome(in: app, strip: Pixel(hex: 0x2563EB), foreground: .light)
        withExtendedLifetime([blue, red]) {}
    }

    /// A page's own background tints the status-bar strip; the bar keeps its glass, which would
    /// vanish into the page if it were filled with the same color.
    func testPageBackgroundTintsStatusBarStripOnly() throws {
        let server = try FixtureServer(html: Self.sandPage)
        let app = launch()
        open(server.url, in: app, expecting: "Sand page")
        assertChrome(in: app, strip: Pixel(hex: 0xFDE68A), foreground: .dark)
        // Glass over the page, not a flat fill in its color: the pill reads lighter than the page.
        let pill = app.buttons["Address"]
        let (fill, _) = Shot(app: app).backgroundAndInk(in: pill.frame.insetBy(dx: 20, dy: 6), percentile: 0)
        XCTAssertGreaterThan(fill.distance(to: Pixel(hex: 0xFDE68A)), 0.03, "pill is filled with the page color: \(fill)")
        withExtendedLifetime(server) {}
    }

    /// In dark mode a page without a theme color gets dark chrome, light on dark: the default, or the
    /// page's own dark background (WebKit's dark canvas is black, a shade off the default).
    func testDarkModePageWithoutThemeColor() throws {
        let server = try FixtureServer(html: Self.plainPage)
        let app = launch(appearance: "dark")
        open(server.url, in: app, expecting: "Plain page")
        assertChrome(in: app, strip: Self.darkDefault, stripTolerance: 0.08, foreground: .light)
        withExtendedLifetime(server) {}
    }

    /// Text on mid-tone tints reads at 4.5:1 in the bar and in the collapsed host strip, whatever
    /// the page shows under the glass.
    func testMidToneTintsStayReadable() throws {
        let blue = try FixtureServer(html: Self.bluePage)
        let sky = try FixtureServer(html: Self.skyPage)
        let app = launch()
        open(blue.url, in: app, expecting: "Blue page")
        assertChrome(in: app, strip: Pixel(hex: 0x2563EB), foreground: .light, minimumContrast: 4.5)
        assertCollapsedStrip(in: app, foreground: .light)

        navigate(to: sky.url, in: app, expecting: "Sky page")
        assertChrome(in: app, strip: Pixel(hex: 0x3B82F6), foreground: .dark, minimumContrast: 4.5)
        assertCollapsedStrip(in: app, foreground: .dark)
        withExtendedLifetime([blue, sky]) {}
    }

    /// A white theme color on a dark-mode system: the chrome matches the page, dark on white.
    func testWhiteThemeColorInDarkMode() throws {
        let server = try FixtureServer(html: Self.whitePage)
        let app = launch(appearance: "dark")
        open(server.url, in: app, expecting: "White page")
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)
        withExtendedLifetime(server) {}
    }

    func testSettingTurnsTintingOff() throws {
        let server = try FixtureServer(html: Self.redPage)
        let app = launch()
        open(server.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        setTinting(false, in: app)
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)
        // And back on.
        setTinting(true, in: app)
        assertChrome(in: app, strip: Self.red, foreground: .light)
        withExtendedLifetime(server) {}
    }

    // MARK: Driving

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    /// - Parameter waitsForIdleAnimations: false for tests that open a context menu, which never
    ///   reports idle on the iOS 27.1 simulator (see LinkContextMenuTests).
    private func launch(appearance: String = "light", waitsForIdleAnimations: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingAppearance", appearance]
        if !waitsForIdleAnimations, app.responds(to: NSSelectorFromString("setIdleAnimationWaitEnabled:")) {
            app.setValue(false, forKey: "idleAnimationWaitEnabled")
        }
        app.launch()
        XCTAssertTrue(searchField(in: app).waitForExistence(timeout: 10), "no search panel at launch")
        return app
    }

    /// Types `url` into the open search panel.
    private func open(_ url: URL, in app: XCUIApplication, expecting title: String) {
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search panel")
        field.typeText(url.absoluteString + "\n")
        // Generous: a fresh simulator is also downloading and compiling the filter lists meanwhile.
        XCTAssertTrue(app.webViews.staticTexts["Body text for \(title)."].waitForExistence(timeout: 30),
                      "\(title) didn't load")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "search panel didn't close on submit")
    }

    /// Loads `url` in the current tab from the address pill.
    private func navigate(to url: URL, in app: XCUIApplication, expecting title: String) {
        app.buttons["Address"].tap()
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The current URL is selected; typing replaces it.
        open(url, in: app, expecting: title)
    }

    private func setTinting(_ on: Bool, in app: XCUIApplication) {
        app.buttons["Page actions"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let toggle = app.switches["Tint with Website Colors"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String == "1") != on {
            // The switch itself, not the row's label.
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
        app.navigationBars["Settings"].buttons["Done"].tap()
        // Swipe the caret sheet away by its grabber.
        let grabber = app.descendants(matching: .any)["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "caret sheet didn't close")
    }

    // MARK: Asserting colors

    private enum Foreground { case light, dark }

    /// Waits out the tint's crossfade, then checks the strip, the status bar on it, and the pill's text.
    /// Before iOS 27 the status bar can't change style, so a tint that needs the other one isn't
    /// drawn there; the strip isn't checked on those systems.
    private func assertChrome(in app: XCUIApplication, strip: Pixel, stripTolerance: Double = 0.04,
                              foreground: Foreground, minimumContrast: Double = 3,
                              file: StaticString = #filePath, line: UInt = #line) {
        if #available(iOS 27, *) {
            assertStrip(in: app, is: strip, tolerance: stripTolerance, file: file, line: line)
            assertStatusBar(in: app, foreground: foreground, file: file, line: line)
        } else {
            // No strip to wait on; give the crossfade time instead.
            RunLoop.current.run(until: .now + 1)
        }
        let pill = app.buttons["Address"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), file: file, line: line)
        let (background, ink) = Shot(app: app).backgroundAndInk(in: pill.frame.insetBy(dx: 20, dy: 6), percentile: 0.98)
        assertReadable(ink, on: background, foreground: foreground, minimumContrast: minimumContrast, "pill",
                       file: file, line: line)
    }

    /// The clock and icons in the strip contrast with it in the expected direction.
    private func assertStatusBar(in app: XCUIApplication, foreground: Foreground, region: CGRect? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard #available(iOS 27, *) else { return }
        guard let region = region ?? Shot.statusStripRegion(app: app) else {
            XCTFail("no status-bar strip beside the web view", file: file, line: line)
            return
        }
        let (background, ink) = Shot(app: app).backgroundAndInk(in: region, percentile: 1)
        assertReadable(ink, on: background, foreground: foreground, minimumContrast: 3, "status bar",
                       file: file, line: line)
    }

    /// Scrolls the page so the bar collapses to the host strip, checks its text, and scrolls back.
    private func assertCollapsedStrip(in app: XCUIApplication, foreground: Foreground,
                                      file: StaticString = #filePath, line: UInt = #line) {
        app.webViews.firstMatch.swipeUp()
        let strip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show toolbar'")).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "bar didn't collapse", file: file, line: line)
        RunLoop.current.run(until: .now + 1)
        let (background, ink) = Shot(app: app).backgroundAndInk(in: strip.frame.insetBy(dx: 10, dy: 3), percentile: 0.98)
        assertReadable(ink, on: background, foreground: foreground, minimumContrast: 4.5, "collapsed strip",
                       file: file, line: line)
        strip.tap()
        XCTAssertTrue(app.buttons["Address"].waitForExistence(timeout: 5), "bar didn't expand", file: file, line: line)
    }

    private func assertReadable(_ ink: Pixel, on background: Pixel, foreground: Foreground, minimumContrast: Double,
                                _ what: String, file: StaticString, line: UInt) {
        let message = "\(what): \(ink) on \(background)"
        switch foreground {
        case .light: XCTAssertGreaterThan(ink.luminance, background.luminance, message, file: file, line: line)
        case .dark: XCTAssertLessThan(ink.luminance, background.luminance, message, file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(ink.contrast(with: background), minimumContrast, message, file: file, line: line)
    }

    /// The strip under the status bar settles on `expected`.
    private func assertStrip(in app: XCUIApplication, is expected: Pixel, tolerance: Double = 0.04, region: CGRect? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let region = region ?? Shot.statusStripRegion(app: app) else {
            XCTFail("no status-bar strip beside the web view", file: file, line: line)
            return
        }
        var last: Pixel?
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            last = Shot(app: app).backgroundAndInk(in: region, percentile: 0).0
            if let last, last.distance(to: expected) <= tolerance { return }
            RunLoop.current.run(until: .now + 0.25)
        } while Date.now < deadline
        XCTFail("status strip is \(last.map { "\($0)" } ?? "missing"), expected \(expected)", file: file, line: line)
    }
}

/// An sRGB color read from a screenshot, components 0...1.
struct Pixel: CustomStringConvertible {
    var red, green, blue: Double

    init(red: Double, green: Double, blue: Double) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: Pixel) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    func distance(to other: Pixel) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }

    var description: String {
        String(format: "#%02X%02X%02X", Int(red * 255 + 0.5), Int(green * 255 + 0.5), Int(blue * 255 + 0.5))
    }
}

/// A screenshot of the app as sRGB pixels, addressed in points.
private struct Shot {
    let width: Int, height: Int, scale: Double
    let bytes: [UInt8]

    @MainActor
    init(app: XCUIApplication) {
        let image = app.screenshot().image
        let cg = image.cgImage!
        width = cg.width
        height = cg.height
        scale = Double(cg.width) / app.frame.width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return Pixel(red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255, blue: Double(bytes[i + 2]) / 255)
    }

    /// The status-bar strip beside the web view, in points: above it on a phone, or the column
    /// next to it where the status bar runs down the side.
    @MainActor
    static func statusStripRegion(app: XCUIApplication) -> CGRect? {
        let web = app.webViews.firstMatch.frame, window = app.frame
        if web.minY >= 8 {
            return CGRect(x: web.minX, y: 0, width: web.width, height: web.minY - 1)
        } else if window.maxX - web.maxX >= 8 {
            return CGRect(x: web.maxX + 1, y: 0, width: window.maxX - web.maxX - 1, height: web.maxY)
        }
        return nil
    }

    /// The commonest color in `rect` (the background) and, at `percentile` of distance from it, the text.
    func backgroundAndInk(in rect: CGRect, percentile: Double) -> (Pixel, Pixel) {
        var samples: [Pixel] = []
        for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 2) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
                samples.append(pixel(x: x, y: y))
            }
        }
        let background = mode(of: samples)
        let sorted = samples.sorted { $0.distance(to: background) < $1.distance(to: background) }
        return (background, sorted[Int(Double(sorted.count - 1) * percentile)])
    }

    private func mode(of pixels: [Pixel]) -> Pixel {
        // Bucketed to 4 bits a channel so glass noise and dithering fall in one bucket.
        var buckets: [Int: [Pixel]] = [:]
        for p in pixels {
            let key = Int(p.red * 15.99) << 8 | Int(p.green * 15.99) << 4 | Int(p.blue * 15.99)
            buckets[key, default: []].append(p)
        }
        let largest = buckets.values.max { $0.count < $1.count } ?? []
        let n = Double(max(largest.count, 1))
        return Pixel(red: largest.map(\.red).reduce(0, +) / n, green: largest.map(\.green).reduce(0, +) / n,
                     blue: largest.map(\.blue).reduce(0, +) / n)
    }
}
