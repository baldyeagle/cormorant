import CormorantCore
import CormorantTestSupport
import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import Cormorant
@testable import CormorantBrowser

extension AppTests {
    /// What the browser screen puts behind the status bar, and the clock's style on it, for the tab on
    /// screen (`BrowserStore.statusBarTint(in:)`, `stripColor(in:)`): the page's background, per page
    /// and per tab, Back included, in light and dark. That the status bar shows it, and the page's
    /// layout under it, is CormorantUITests' StatusBarTests, read from screenshots.
    @Suite("Status bar tint")
    @MainActor
    struct StatusBarTintTests {
        private static let red = RGBColor(hex: 0xB91C1C)
        /// The default chrome (the launch background).
        private static let lightDefault = RGBColor(hex: 0xFFFFFF)
        private static let darkDefault = RGBColor(hex: 0x030712)

        /// A page in `background` (the canvas's own without one).
        private static func page(title: String, background: String? = nil, head: String = "") -> String {
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
            """
        }

        private static let redPage = page(title: "Red page", background: "#b91c1c")
        private static let plainPage = page(title: "Plain page")
        /// White, with a pale blue fixed header, which WebKit carries up behind the status bar: the
        /// clock goes by the page's background.
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

        /// One tab through pages (Back included), then a second tab and back.
        @Test func followsEachPageAndTab() async throws {
            let red = try FixtureServer(html: Self.redPage)
            let header = try FixtureServer(html: Self.headerPage)
            let plain = try FixtureServer(html: Self.plainPage)
            let browser = try await TestBrowser()
            defer { browser.close() }
            browser.store.submit(red.url.absoluteString)
            try await browser.waitForPage(at: red.url)
            try await browser.waitForStatusBar(on: Self.red, foreground: .light)
            let redTab = try #require(browser.store.state.activeTabID)

            // The same tab, from its Edit row.
            browser.store.submit(header.url.absoluteString)
            try await browser.waitForPage(at: header.url)
            try await browser.waitForStatusBar(on: Self.lightDefault, foreground: .dark)

            browser.store.activeSession?.goBack()
            try await browser.waitForPage(at: red.url)
            try await browser.waitForStatusBar(on: Self.red, foreground: .light)

            // A second tab, on a page without a color of its own.
            browser.store.newTab()
            browser.store.submit(plain.url.absoluteString)
            try await browser.waitForPage(at: plain.url)
            #expect(browser.store.tabs.count == 2)
            try await browser.waitForStatusBar(on: Self.lightDefault, foreground: .dark)

            // Back to the first.
            browser.store.activate(redTab)
            try await browser.waitForPage(at: red.url)
            try await browser.waitForStatusBar(on: Self.red, foreground: .light)
            withExtendedLifetime([red, header, plain]) {}
        }

        /// Dark mode: a page with a dark variant gets a dark status bar area; a light-only white page
        /// keeps a dark clock, which the system's own dark-mode style would lose on it.
        @Test func darkMode() async throws {
            let plain = try FixtureServer(html: Self.plainPage)
            let white = try FixtureServer(html: Self.whitePage)
            // As the app in dark mode: its window, and with it the tab's web view and its pages.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes { scene.traitOverrides.userInterfaceStyle = .dark }
            defer { for scene in scenes { scene.traitOverrides.remove(UITraitUserInterfaceStyle.self) } }
            let browser = try await TestBrowser()
            defer { browser.close() }

            browser.store.submit(plain.url.absoluteString)
            try await browser.waitForPage(at: plain.url)
            try await browser.waitForStatusBar(on: Self.darkDefault, tolerance: 0.1, foreground: .light, in: .dark)

            browser.store.submit(white.url.absoluteString)
            try await browser.waitForPage(at: white.url)
            try await browser.waitForStatusBar(on: Self.lightDefault, foreground: .dark, in: .dark)
            withExtendedLifetime([plain, white]) {}
        }
    }
}

fileprivate extension TestBrowser {
    /// Waits until the tab on screen has finished loading `url` (the fixture servers here all serve `/`).
    func waitForPage(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until("the tab on screen to load \(url) (it's at \(store.activeSession?.webView.url?.absoluteString ?? "nothing"))",
                        sourceLocation: sourceLocation) {
            guard let session = store.activeSession else { return false }
            return session.webView.url?.absoluteString == url.absoluteString && !session.isLoading
        }
    }

    /// Waits until, in `scheme`, the status bar is on `expected` (to within `tolerance` a channel) with
    /// a `foreground` clock, as the browser screen draws it from the tab on screen's page: its color
    /// once settled and read in this appearance, after the first page has drawn.
    func waitForStatusBar(on expected: RGBColor, tolerance: Double = 0.04, foreground: ChromeTint.Foreground,
                          in scheme: ColorScheme = .light, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until("the status bar to be on \(expected) with a \(foreground) clock (it's \(statusBar(in: scheme).map { "\($0.foreground) on \($0.background)" } ?? "unsettled"))",
                        sourceLocation: sourceLocation) {
            guard let shown = statusBar(in: scheme) else { return false }
            return shown.background.distance(to: expected) <= tolerance && shown.foreground == foreground
        }
    }

    /// The status bar's background and clock for the tab on screen, in `scheme`; nil until its page's
    /// color has settled in that appearance and the first page has drawn.
    private func statusBar(in scheme: ColorScheme) -> (background: RGBColor, foreground: ChromeTint.Foreground)? {
        guard let session = store.activeSession, session.pageBackground?.appearance == Appearance(scheme),
              !session.isAwaitingFirstPaint else { return nil }
        let tint = store.statusBarTint(in: scheme)
        // No tint: the default strip (`stripColor(in:)`), with the system's style for the appearance
        // (`statusBarColorScheme(nil)`).
        return (background: tint?.background ?? .launchBackground(in: scheme),
                foreground: tint?.foreground ?? (scheme == .dark ? .light : .dark))
    }
}
