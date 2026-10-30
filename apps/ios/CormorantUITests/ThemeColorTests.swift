import UIKit
import XCTest

/// Site-tinted chrome: the strip behind the status bar continues the top of the page, per tab, with a
/// status bar that reads on it, and goes back to the default without a color. The bottom bar never
/// takes a site's color. Colors are read from screenshots, each check waiting (`waitUntil`) for the
/// strip to arrive rather than for a fixed time.
@MainActor
final class ThemeColorTests: UITestCase {
    private static let red = Pixel(hex: 0xB91C1C)
    private static let navy = Pixel(hex: 0x1E3A8A)
    private static let blue = Pixel(hex: 0x2563EB)
    private static let black = Pixel(hex: 0x000000)
    /// The default chrome (the launch background).
    private static let lightDefault = Pixel(hex: 0xFFFFFF)
    private static let darkDefault = Pixel(hex: 0x030712)

    /// A page starting with a `top` band (flush with the top edge) when given one.
    private static func page(title: String, head: String = "", top: String? = nil, body: String = "") -> String {
        """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        <style>body { margin: 0 } h1, p { margin: 12px 16px }</style>
        \(head)
        <title>\(title)</title>
        \(top.map { #"<div style="height: 96px; \#($0)"></div>"# } ?? "")
        <h1>\(title)</h1>
        <p>Body text for \(title).</p>
        \(body)
        """
    }

    /// Theme color and top band agree: the strip takes the color exactly.
    private static let redPage = page(title: "Red page", head: ##"<meta name="theme-color" content="#b91c1c">"##,
                                      top: "background: #b91c1c")
    private static let plainPage = page(title: "Plain page")
    private static let bluePage = page(title: "Blue page", head: ##"<meta name="theme-color" content="#2563eb">"##,
                                       top: "background: #2563eb")
    /// Like GitHub: a dark theme-color above a light banner, then a dark hero.
    private static let bannerPage = page(
        title: "Banner page", head: ##"<meta name="theme-color" content="#1e2327">"##,
        top: "background: #eef1f0",
        body: #"<div style="height: 3000px; background: #0a104e"></div>"#)
    /// Light-only, like many sites: white whatever the system appearance.
    private static let whitePage = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="theme-color" content="#ffffff">
        <title>White page</title>
        <h1>White page</h1>
        <p>Body text for White page.</p>
        """
    /// A theme color and top band per appearance.
    private static let schemePage = page(title: "Scheme page", head: """
        <meta name="theme-color" media="(prefers-color-scheme: light)" content="#fde047">
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#1e3a8a">
        <style>
          .band { background: #fde047 }
          @media (prefers-color-scheme: dark) { .band { background: #1e3a8a } }
        </style>
        """).replacingOccurrences(of: "<h1>", with: #"<div class="band" style="height: 96px"></div><h1>"#)
    /// Red, long enough to pull, counting its loads in `sessionStorage` (it survives a reload) and its
    /// touch moves (to tell a dropped drag from one that didn't reload).
    private static let refreshPage = page(title: "Refresh page", head: ##"""
        <meta name="theme-color" content="#b91c1c">
        <script>
          sessionStorage.loads = Number(sessionStorage.loads || 0) + 1;
          let moves = 0;
          addEventListener("DOMContentLoaded", () => {
            document.getElementById("count").textContent = "Load " + sessionStorage.loads;
          });
          addEventListener("touchmove", () => {
            document.getElementById("moves").textContent = "Touch moves: " + ++moves;
          }, { passive: true });
        </script>
        """##, top: "background: #b91c1c",
        body: #"<p id="count">Loading</p><p id="moves">Touch moves: 0</p>"# + filler)
    private static let filler = String(repeating: "<p>Filler text, line after line.</p>", count: 80)

    /// A red page with a link to `target`, set up for `pressForLinkMenu` (a "Path" paragraph to tap
    /// and its selection report).
    private static func linkPage(to target: URL) -> String {
        page(title: "Red page", head: ##"<meta name="theme-color" content="#b91c1c">"##, top: "background: #b91c1c",
             body: #"<p>Path /</p><a href="\#(target.absoluteString)" style="display: block; font-size: 24px">Blue link</a>"#
                + selectionReport)
    }

    /// One tab through three pages: a color, no color (back to the default), and Back to the first
    /// (its color again).
    func testStripFollowsEachPageInATab() throws {
        let red = try FixtureServer(html: Self.redPage)
        let plain = try FixtureServer(html: Self.plainPage)
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light, untintedOver: Self.red)

        navigate(to: plain.url, from: "Red page", in: app, expecting: "Plain page")
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)

        app.buttons["Page actions"].tapWhenSettled()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.appears(within: Ceiling.ui), "caret sheet didn't open")
        back.tap()
        XCTAssertTrue(app.webViews.staticTexts["Body text for Red page."].appears(within: Ceiling.load), "Back didn't go back")
        XCTAssertTrue(app.buttons["Settings"].disappears(within: Ceiling.ui), "Back didn't close the caret sheet")
        assertChrome(in: app, strip: Self.red, foreground: .light)
        withExtendedLifetime([red, plain]) {}
    }

    /// GitHub's case: the theme color isn't what's at the top of the page. The strip follows the page,
    /// and follows it again once a scroll has put something else at the top.
    func testStripFollowsThePageTopNotAMismatchedThemeColor() throws {
        let server = try FixtureServer(html: Self.bannerPage)
        let app = launch()
        open(server.url, in: app, expecting: "Banner page")
        assertChrome(in: app, strip: Pixel(hex: 0xEEF1F0), foreground: .dark, untintedOver: Pixel(hex: 0x1E2327))

        app.webViews.firstMatch.swipeUp()
        assertChrome(in: app, strip: Pixel(hex: 0x0A104E), foreground: .light)
        withExtendedLifetime(server) {}
    }

    func testTintIsPerTab() throws {
        let red = try FixtureServer(html: Self.redPage)
        let plain = try FixtureServer(html: Self.plainPage)
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        // A new tab on a page without a color.
        app.buttons["Tabs, 1 open"].tapWhenSettled()
        let newTab = app.toolbars.buttons["New Tab"]
        XCTAssertTrue(newTab.appears(within: Ceiling.ui), "switcher didn't open")
        newTab.tapWhenSettled()
        open(plain.url, in: app, expecting: "Plain page")
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)

        // Back to the red tab.
        app.buttons["Tabs, 2 open"].tapWhenSettled()
        let card = tabCards(in: app).matching(NSPredicate(format: "label == 'Red page'")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for the red tab")
        tapSliver(of: card, in: app)
        XCTAssertTrue(app.webViews.staticTexts["Body text for Red page."].appears(within: Ceiling.load))
        assertChrome(in: app, strip: Self.red, foreground: .light)
        withExtendedLifetime([red, plain]) {}
    }

    /// Dark mode: WebKit resolves `media="(prefers-color-scheme: dark)"` theme colors and pages; a
    /// light-only white page keeps a white strip (dark on white); a page without colors gets a dark
    /// strip, the default or the page's own dark canvas a shade off it.
    func testDarkModeColors() throws {
        let scheme = try FixtureServer(html: Self.schemePage)
        let white = try FixtureServer(html: Self.whitePage)
        let plain = try FixtureServer(html: Self.plainPage)
        let app = launch(appearance: "dark")
        open(scheme.url, in: app, expecting: "Scheme page")
        assertChrome(in: app, strip: Self.navy, foreground: .light, untintedOver: Self.navy)

        navigate(to: white.url, from: "Scheme page", in: app, expecting: "White page")
        assertChrome(in: app, strip: Self.lightDefault, foreground: .dark)

        navigate(to: plain.url, from: "White page", in: app, expecting: "Plain page")
        assertChrome(in: app, strip: Self.darkDefault, stripTolerance: 0.08, foreground: .light)
        withExtendedLifetime([scheme, white, plain]) {}
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

    /// Tapping a link's preview opens it in a new tab with the preview's page: the strip has that
    /// page's color from the start.
    func testPreviewTapOpensWithTheLinkedPagesColor() throws {
        let blue = try FixtureServer(html: Self.bluePage)
        let red = try FixtureServer(html: Self.linkPage(to: blue.url))
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        let previewText = app.webViews.staticTexts["Body text for Blue page."]
        XCTAssertTrue(pressForLinkMenu(app.webViews.links["Blue link"], until: previewText, in: app),
                      "the preview didn't load")
        // The preview's content isn't hittable; tap where it is, once it has stopped growing.
        let frame = previewText.settledFrame()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(app.buttons["Open Link"].disappears(within: Ceiling.ui), "menu didn't close")
        app.waitsForAnimations = true
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui), "no new tab")
        assertChrome(in: app, strip: Self.blue, foreground: .light, untintedOver: Self.blue)
        withExtendedLifetime([blue, red]) {}
    }

    /// Like GitHub and Discord: a sticky header that changes color once the page has scrolled a way,
    /// here to `oklch(0 0 0)`, as Tailwind 4 writes colors, under a Content-Security-Policy that lets
    /// only the page's own (nonced) script run. "Down" has the page scroll itself 1200 pt, "Up" back
    /// to the top; the header turns black past 600 pt and navy again above it.
    private static let stickyPage = """
        <!doctype html>
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="script-src 'nonce-cormorant'">
        <title>Sticky page</title>
        <style>
          body { margin: 0 }
          header { position: sticky; top: 0; height: 64px; background: #1e3a8a; transition: background-color .2s }
          header.scrolled { background: oklch(0 0 0) }
          .hero { height: 240px; background: #1e3a8a }
          button { position: fixed; left: 16px; font-size: 24px }
          p { margin: 12px 16px; height: 40px }
        </style>
        <header id="header"></header>
        <div class="hero"></div>
        <button id="down" style="top: 35%">Down</button>
        <button id="up" style="top: 50%">Up</button>
        <p>Body text for Sticky page.</p>
        \(String(repeating: "<p>Filler.</p>", count: 80))
        <script nonce="cormorant">
          addEventListener("scroll", () => header.classList.toggle("scrolled", scrollY > 600));
          const glide = (to) => {
            const from = scrollY, start = performance.now();
            const step = () => {
              const t = Math.min(1, (performance.now() - start) / 1500);
              scrollTo(0, from + (to - from) * t);
              if (t < 1) requestAnimationFrame(step);
            };
            requestAnimationFrame(step);
          };
          down.onclick = () => glide(1200);
          up.onclick = () => glide(0);
        </script>
        """

    /// The strip follows the top of the page while it scrolls, not only once it rests: the header's
    /// new color reaches the strip from the page's script (which the app reports under -uiTesting),
    /// not just from the snapshot taken at rest, which would put the same color there.
    func testStripFollowsAStickyHeaderWhileScrolling() throws {
        let server = try FixtureServer(html: Self.stickyPage)
        let app = launch()
        open(server.url, in: app, expecting: "Sticky page")
        assertChrome(in: app, strip: Self.navy, foreground: .light)

        let live = app.descendants(matching: .any)["UITesting.pageTop"].firstMatch
        for (button, color) in [("Down", Self.black), ("Up", Self.navy)] {
            app.webViews.buttons[button].tapWhenSettled()
            XCTAssertTrue(waitUntil(Ceiling.ui, "Waiting for the page's script to report \(color)") {
                live.value as? String == "\(color)"
            }, "scrolling \(button.lowercased()), the script's last color was \((live.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "none"), not \(color)")
            assertChrome(in: app, strip: color, foreground: .light)
        }
        withExtendedLifetime(server) {}
    }

    /// Pull to refresh on a tinted page: the reload goes through, and the color holds through it (the
    /// spinner's overscroll and WebKit's interim colors never reach the strip).
    func testPullToRefreshKeepsTint() throws {
        let server = try FixtureServer(html: Self.refreshPage)
        let app = launch()
        open(server.url, in: app, expecting: "Refresh page")
        XCTAssertTrue(app.webViews.staticTexts["Load 1"].appears(within: Ceiling.load))
        assertChrome(in: app, strip: Self.red, foreground: .light)

        let reloaded = app.webViews.staticTexts["Load 2"]
        pull(in: app)
        // Right after a fresh install the simulator can drop a synthesized drag entirely (the touch
        // begins and ends without moving). Only then, pull once more (as PullToRefreshTests does).
        if !reloaded.appears(within: 8), app.webViews.staticTexts["Load 1"].exists,
           app.webViews.staticTexts["Touch moves: 0"].exists {
            pull(in: app)
        }
        XCTAssertTrue(reloaded.appears(within: Ceiling.load), "pull didn't reload")
        assertChrome(in: app, strip: Self.red, foreground: .light)
        // The pull mustn't have left the bar collapsed.
        XCTAssertTrue(app.buttons["NewTabPill"].exists, "bar collapsed after the pull")
        withExtendedLifetime(server) {}
    }

    /// A link opened from the long-press menu: neither its preview (a separate web view) nor a
    /// background tab for it changes this tab's strip; switching to that tab does.
    func testLinkMenuBackgroundTabKeepsTintUntilShown() throws {
        let blue = try FixtureServer(html: Self.bluePage)
        let red = try FixtureServer(html: Self.linkPage(to: blue.url))
        let app = launch()
        open(red.url, in: app, expecting: "Red page")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        let item = app.buttons["Open in Background Tab"]
        XCTAssertTrue(pressForLinkMenu(app.webViews.links["Blue link"], until: item, in: app), "no link menu")
        XCTAssertTrue(waitUntil(Ceiling.ui) { item.isHittable }, "Open in Background Tab isn't hittable")
        // Hittable while the menu is still springing open, when UIKit takes a tap as a dismissal.
        item.tapWhenSettled()
        XCTAssertTrue(item.disappears(within: Ceiling.ui), "menu didn't close")
        app.waitsForAnimations = true
        XCTAssertTrue(app.buttons["Tabs, 2 open"].appears(within: Ceiling.ui), "no background tab")
        assertChrome(in: app, strip: Self.red, foreground: .light)

        app.buttons["Tabs, 2 open"].tapWhenSettled()
        // Titled once it has loaded on the background stage; the host until then.
        let card = tabCards(in: app).matching(NSPredicate(format: "label == 'Blue page' OR label == '127.0.0.1'")).firstMatch
        XCTAssertTrue(card.appears(within: Ceiling.ui), "no card for the background tab")
        tapSliver(of: card, in: app)
        XCTAssertTrue(app.webViews.staticTexts["Body text for Blue page."].appears(within: Ceiling.load))
        assertChrome(in: app, strip: Self.blue, foreground: .light, untintedOver: Self.blue)
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

    /// A slow drag from near the top of the page to past the middle, held, then released.
    private func pull(in app: XCUIApplication) {
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func setTinting(_ on: Bool, in app: XCUIApplication) {
        app.buttons["Page actions"].tapWhenSettled()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.appears(within: Ceiling.ui), "caret sheet didn't open")
        settings.tap()
        let toggle = app.switches["Tint with Website Colors"]
        XCTAssertTrue(toggle.appears(within: Ceiling.ui), "Settings didn't open")
        if (toggle.value as? String == "1") != on {
            // The switch itself, not the row's label.
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        }
        XCTAssertTrue(waitUntil(Ceiling.ui) { toggle.value as? String == (on ? "1" : "0") }, "the setting didn't change")
        let done = app.navigationBars["Settings"].buttons["Done"]
        done.tap()
        XCTAssertTrue(done.disappears(within: Ceiling.ui), "Settings didn't close")
        dismissCaretSheet(in: app)
    }

    /// Swipes the caret sheet away by its grabber.
    private func dismissCaretSheet(in app: XCUIApplication) {
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

    /// Waits for the strip to arrive at `strip` with a status bar that reads on it, and checks that the
    /// bottom bar is the plain glass it always is: not in `untintedOver` (the page's theme color).
    /// (Plain glass isn't always high-contrast, e.g. on a white page in dark mode; that's the system's.)
    /// Before iOS 27 the status bar can't change style, so a color that needs the other one isn't
    /// drawn there; the strip isn't checked on those systems.
    private func assertChrome(in app: XCUIApplication, strip expected: Pixel, stripTolerance: Double = 0.04,
                              foreground: Foreground, untintedOver themeColor: Pixel? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        if #available(iOS 27, *) {
            assertStrip(in: app, is: expected, tolerance: stripTolerance, foreground: foreground, file: file, line: line)
        }
        guard let themeColor else { return }
        let pill = app.buttons["NewTabPill"]
        XCTAssertTrue(pill.appears(within: Ceiling.ui), file: file, line: line)
        let frame = pill.settledFrame()
        let (background, _) = Shot(app: app).backgroundAndInk(in: frame.insetBy(dx: 6, dy: 6), percentile: 0.98)
        XCTAssertGreaterThan(background.distance(to: themeColor), 0.15,
                             "the bar took the site's color: pill \(background)", file: file, line: line)
    }

    /// The strip under the status bar arrives at `expected` (a settle, a snapshot and a fade after the
    /// page does), and in the same screenshot the clock and icons on it contrast with it in the
    /// `foreground` direction (the status bar changes style at the fade's midpoint).
    private func assertStrip(in app: XCUIApplication, is expected: Pixel, tolerance: Double,
                             foreground: Foreground, file: StaticString = #filePath, line: UInt = #line) {
        guard let region = Shot.statusStripRegion(app: app) else {
            XCTFail("no status-bar strip beside the web view", file: file, line: line)
            return
        }
        var last: (background: Pixel, ink: Pixel)?
        let arrived = waitUntil(Ceiling.ui, "Waiting for the status-bar strip to be \(expected)") {
            let (background, ink) = Shot(app: app).backgroundAndInk(in: region, percentile: 1)
            last = (background, ink)
            let direction = switch foreground {
            case .light: ink.luminance > background.luminance
            case .dark: ink.luminance < background.luminance
            }
            return background.distance(to: expected) <= tolerance && direction && ink.contrast(with: background) >= 3
        }
        XCTAssertTrue(arrived, "status strip is \(last.map { "\($0.background) with \($0.ink) on it" } ?? "unread"), "
                      + "expected \(expected) with \(foreground) text", file: file, line: line)
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
        // Settled: a page that just appeared may still be sliding into place.
        let web = app.webViews.firstMatch.settledFrame(), window = app.frame
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
