import UIKit
import XCTest

/// The status bar over the page: the page runs up under it (unless that's off), the clock takes its
/// style from the page's background, and the iPhone Duo's status-bar column takes that color. Per
/// page and per tab. Colors are read from screenshots, each check waiting (`waitUntil`) for them to
/// arrive rather than for a fixed time. Running under is only checked where the status bar runs
/// along the top: the iPhone Duo's (CI's) is a column beside the page.
@MainActor
final class StatusBarTests: UITestCase {
    private static let red = Pixel(hex: 0xB91C1C)
    private static let blue = Pixel(hex: 0x2563EB)
    private static let paleBlue = Pixel(hex: 0xBFDBFE)
    /// The default chrome (the launch background).
    private static let lightDefault = Pixel(hex: 0xFFFFFF)
    private static let darkDefault = Pixel(hex: 0x030712)

    /// A page in `background` (the canvas's own without one), its text clear of the status bar.
    private static func page(title: String, background: String? = nil, head: String = "", body: String = "") -> String {
        """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        <style>body { margin: 0; padding-top: 40px\(background.map { "; background: \($0); color: white" } ?? "") }
        h1, p { margin: 12px 16px }</style>
        \(head)
        <title>\(title)</title>
        <h1>\(title)</h1>
        <p>Body text for \(title).</p>
        \(body)
        """
    }

    private static let redPage = page(title: "Red page", background: "#b91c1c")
    private static let bluePage = page(title: "Blue page", background: "#2563eb")
    private static let plainPage = page(title: "Plain page")
    /// White, with a pale blue fixed header: where the page runs under the status bar, the header is
    /// laid out below it and WebKit carries its color up behind it. The clock goes by the page's
    /// background.
    private static let headerPage = page(title: "Header page", head: """
        <style>header { position: fixed; top: 0; left: 0; right: 0; height: 64px; background: #bfdbfe }
        header p { margin: 0 16px; line-height: 64px; color: #1e3a8a }
        body { padding-top: 76px }</style>
        <header><p>Header bar</p></header>
        """)
    /// Light-only, like many sites: white whatever the system appearance.
    private static let whitePage = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <style>body { margin: 0; padding-top: 40px } h1, p { margin: 12px 16px }</style>
        <title>White page</title>
        <h1>White page</h1>
        <p>Body text for White page.</p>
        """

    /// A red page with a link to `target`, set up for `pressForLinkMenu` (a "Path" paragraph to tap
    /// and its selection report).
    private static func linkPage(to target: URL) -> String {
        page(title: "Red page", background: "#b91c1c",
             body: #"<p>Path /</p><a href="\#(target.absoluteString)" style="display: block; font-size: 24px; color: white">Blue link</a>"#
                + selectionReport)
    }

    /// One tab through pages (Back included), then a second tab and back: each page's color, the
    /// clock reading on it, and the page running under the status bar.
    func testStatusBarFollowsEachPageAndTab() throws {
        let red = try FixtureServer(html: Self.redPage)
        let header = try FixtureServer(html: Self.headerPage)
        let plain = try FixtureServer(html: Self.plainPage)
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertStatusBar(in: app, on: Self.red, foreground: .light, pageRunsUnder: true)

        navigate(to: header.url, from: "Red page", in: app, expecting: "Header page")
        // The header's color where it's carried up behind the status bar; the page's (white) in a column.
        assertStatusBar(in: app, on: Self.paleBlue, columnOn: Self.lightDefault, foreground: .dark)
        let (region, runsUnder) = Shot.statusBarRegion(app: app)
        if runsUnder {
            // Laid out below the status bar, not under it (WebKit is told it's covered).
            let headerText = app.webViews.staticTexts["Header bar"]
            XCTAssertTrue(headerText.appears(within: Ceiling.ui), "no header")
            XCTAssertGreaterThanOrEqual(headerText.settledFrame().minY, region.maxY, "the header is under the status bar")
        }

        app.buttons["Page actions"].tapWhenSettled()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.appears(within: Ceiling.ui), "caret sheet didn't open")
        back.tap()
        XCTAssertTrue(app.webViews.staticTexts["Body text for Red page."].appears(within: Ceiling.load), "Back didn't go back")
        XCTAssertTrue(app.buttons["Settings"].disappears(within: Ceiling.ui), "Back didn't close the caret sheet")
        assertStatusBar(in: app, on: Self.red, foreground: .light)

        // A second tab, on a page without a color of its own.
        app.buttons["Tabs, 1 open"].tapWhenSettled()
        let newTab = app.toolbars.buttons["New Tab"]
        XCTAssertTrue(newTab.appears(within: Ceiling.ui), "switcher didn't open")
        newTab.tapWhenSettled()
        open(plain.url, in: app, expecting: "Plain page")
        assertStatusBar(in: app, on: Self.lightDefault, foreground: .dark)

        // Back to the first.
        app.buttons["Tabs, 2 open"].tapWhenSettled()
        let card = tabCards(in: app).matching(NSPredicate(format: "label == 'Red page'")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for the red tab")
        tapSliver(of: card, in: app)
        XCTAssertTrue(app.webViews.staticTexts["Body text for Red page."].appears(within: Ceiling.load))
        assertStatusBar(in: app, on: Self.red, foreground: .light)
        withExtendedLifetime([red, header, plain]) {}
    }

    /// Dark mode: a page with a dark variant gets a dark status bar area; a light-only white page
    /// keeps a dark clock, which the system's own dark-mode style would lose on it.
    func testDarkMode() throws {
        let plain = try FixtureServer(html: Self.plainPage)
        let white = try FixtureServer(html: Self.whitePage)
        let app = launch(appearance: "dark")
        open(plain.url, in: app, expecting: "Plain page")
        assertStatusBar(in: app, on: Self.darkDefault, tolerance: 0.1, foreground: .light)

        navigate(to: white.url, from: "Plain page", in: app, expecting: "White page")
        assertStatusBar(in: app, on: Self.lightDefault, foreground: .dark)
        withExtendedLifetime([plain, white]) {}
    }

    /// Off, the page stops below the status bar, which sits on the default strip in the system's
    /// style; back on, the page runs under it again.
    func testSettingTurnsItOff() throws {
        let server = try FixtureServer(html: Self.redPage)
        let app = launch()
        open(server.url, in: app, expecting: "Red page")
        assertStatusBar(in: app, on: Self.red, foreground: .light, pageRunsUnder: true)

        setPageUnderStatusBar(false, in: app)
        assertStatusBar(in: app, on: Self.lightDefault, foreground: .dark, pageRunsUnder: false)
        setPageUnderStatusBar(true, in: app)
        assertStatusBar(in: app, on: Self.red, foreground: .light, pageRunsUnder: true)
        withExtendedLifetime(server) {}
    }

    /// Tapping a link's preview opens it in a new tab that takes over the preview's page: its color
    /// is there from the start, with no navigation to report it.
    func testPreviewTapOpensWithTheLinkedPagesColor() throws {
        let blue = try FixtureServer(html: Self.bluePage)
        let red = try FixtureServer(html: Self.linkPage(to: blue.url))
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertStatusBar(in: app, on: Self.red, foreground: .light)

        let previewText = app.webViews.staticTexts["Body text for Blue page."]
        XCTAssertTrue(pressForLinkMenu(app.webViews.links["Blue link"], until: previewText, in: app),
                      "the preview didn't load")
        tapLinkPreview(in: app)
        XCTAssertTrue(app.buttons["Open Link"].disappears(within: Ceiling.ui), "menu didn't close")
        app.waitsForAnimations = true
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui), "no new tab")
        assertStatusBar(in: app, on: Self.blue, foreground: .light)
        withExtendedLifetime([blue, red]) {}
    }

    // MARK: Driving

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter address"]
    }

    private func launch(appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingAppearance", appearance]
        app.launch()
        XCTAssertTrue(searchField(in: app).appears(within: Ceiling.launch), "no search panel at launch")
        return app
    }

    /// Types `url` into the open search panel.
    private func open(_ url: URL, in app: XCUIApplication, expecting title: String) {
        let field = searchField(in: app)
        XCTAssertTrue(field.appears(within: Ceiling.ui), "no search panel")
        field.typeText(url.absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Body text for \(title)."].appears(within: Ceiling.load),
                      "\(title) didn't load")
        XCTAssertTrue(field.disappears(within: Ceiling.ui), "search panel didn't close on submit")
    }

    /// Loads `url` in the current tab, titled `current`: the + pill's panel, then its row for this tab.
    private func navigate(to url: URL, from current: String, in app: XCUIApplication, expecting title: String) {
        // The bar slides down with the keyboard after the search panel closes; a tap while it moves is dropped.
        app.buttons["NewTabPill"].tapWhenSettled()
        let row = app.buttons["Edit address: \(current)"]
        XCTAssertTrue(row.appears(within: Ceiling.ui), "no row for the current tab")
        row.tapWhenSettled()
        let field = searchField(in: app)
        XCTAssertTrue(waitUntil(Ceiling.ui) { (field.value as? String)?.hasPrefix("http") == true },
                      "the field didn't take the tab's address")
        // The current URL is selected; typing replaces it.
        open(url, in: app, expecting: title)
    }

    private func setPageUnderStatusBar(_ on: Bool, in app: XCUIApplication) {
        app.buttons["Page actions"].tapWhenSettled()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.appears(within: Ceiling.ui), "caret sheet didn't open")
        settings.tap()
        let title = app.navigationBars["Settings"]
        XCTAssertTrue(title.appears(within: Ceiling.ui), "Settings didn't open")
        // Below the default-browser and search-engine sections, off a short screen, where the form
        // hasn't made its row yet: drag the form up (no fling) until it has.
        let toggle = app.switches["Page Under Status Bar"]
        let top = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
        for _ in 0..<4 where !toggle.exists {
            top.withOffset(CGVector(dx: 0, dy: 360))
                .press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 60)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(toggle.appears(within: Ceiling.ui), "no Page Under Status Bar setting")
        if (toggle.value as? String == "1") != on {
            // The switch itself, not the row's label.
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        }
        XCTAssertTrue(waitUntil(Ceiling.ui) { toggle.value as? String == (on ? "1" : "0") }, "the setting didn't change")
        // Scrolled down, the sheet's bar shows no items: back up until Done is there again.
        let done = app.navigationBars["Settings"].buttons["Done"]
        for _ in 0..<4 where !done.exists {
            top.withOffset(CGVector(dx: 0, dy: 60))
                .press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 360)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(done.appears(within: Ceiling.ui), "no Done button")
        done.tapWhenSettled()
        XCTAssertTrue(done.disappears(within: Ceiling.ui), "Settings didn't close")
        // Swipes the caret sheet away by its grabber.
        let grabber = app.descendants(matching: .any)["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.appears(within: Ceiling.ui))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.buttons["Settings"].disappears(within: Ceiling.ui), "caret sheet didn't close")
    }

    /// The switcher's cards (each one accessibility element, labeled with its tab's title).
    private func tabCards(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'TabCard'"))
    }

    /// An older tab's card sits behind the current tab's, mostly off screen: taps the sliver that
    /// shows, once the switcher has stopped moving.
    private func tapSliver(of card: XCUIElement, in app: XCUIApplication) {
        let frame = card.settledFrame()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: max(frame.minX, 0) + 20, dy: frame.midY)).tap()
    }

    // MARK: Asserting colors

    private enum Foreground { case light, dark }

    /// Waits for the status bar to be on `expected` (`columnOn` where it's a column beside the page,
    /// if that differs) with its clock and icons contrasting in the `foreground` direction, both read
    /// from the same screenshot. `pageRunsUnder`: where the status bar is along the top, whether the
    /// page should run under it.
    private func assertStatusBar(in app: XCUIApplication, on expected: Pixel, columnOn column: Pixel? = nil,
                                 tolerance: Double = 0.04, foreground: Foreground, pageRunsUnder: Bool? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let (region, runsUnder) = Shot.statusBarRegion(app: app)
        let isColumn = region.minX > 0
        if let pageRunsUnder, !isColumn {
            XCTAssertEqual(runsUnder, pageRunsUnder, "the page \(runsUnder ? "runs" : "doesn't run") under the status bar",
                           file: file, line: line)
        }
        let expected = isColumn ? column ?? expected : expected
        var last: (background: Pixel, ink: Pixel)?
        let arrived = waitUntil(Ceiling.ui, "Waiting for the status bar to be on \(expected)") {
            let (background, ink) = Shot(app: app).backgroundAndInk(in: region, percentile: 1)
            last = (background, ink)
            let direction = switch foreground {
            case .light: ink.luminance > background.luminance
            case .dark: ink.luminance < background.luminance
            }
            return background.distance(to: expected) <= tolerance && direction && ink.contrast(with: background) >= 3
        }
        XCTAssertTrue(arrived, "the status bar is \(last.map { "\($0.ink) on \($0.background)" } ?? "unread"), "
                      + "expected \(foreground) text on \(expected)", file: file, line: line)
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

    /// Where the status bar is, in points, and whether the page runs under it: the column beside the
    /// page where the status bar runs down the side (iPhone Duo), else the strip above the page, or
    /// the top of the page itself where it runs under the status bar (as high as any status bar).
    @MainActor
    static func statusBarRegion(app: XCUIApplication) -> (rect: CGRect, pageRunsUnder: Bool) {
        // Settled: a page that just appeared may still be sliding into place.
        let web = app.webViews.firstMatch.settledFrame(), window = app.frame
        if window.maxX - web.maxX >= 8 {
            // Its top part, where the clock and icons are: the rest of the column is only background.
            return (CGRect(x: web.maxX + 1, y: 0, width: window.maxX - web.maxX - 1, height: min(web.maxY, 240)), false)
        } else if web.minY >= 8 {
            return (CGRect(x: web.minX, y: 0, width: web.width, height: web.minY - 1), false)
        }
        return (CGRect(x: web.minX, y: 0, width: web.width, height: 44), true)
    }

    /// The commonest color in `rect` (the background) and, at `percentile` of distance from it, the text.
    func backgroundAndInk(in rect: CGRect, percentile: Double) -> (Pixel, Pixel) {
        var samples: [Pixel] = []
        // Every few pixels: the strip can be a full-height column, and this runs on every check.
        let step = max(2, Int(scale * 1.5))
        for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: step) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: step) {
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
