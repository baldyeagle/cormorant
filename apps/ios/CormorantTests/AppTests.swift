import Testing
@testable import Cormorant
@testable import CormorantBrowser

/// Every in-process test, one at a time. They share the app's main actor, WebKit's processes and its
/// website data stores, so two at once would see each other's pages and profiles. Each file adds its
/// suite as an extension, which `.serialized` reaches (it applies to nested suites too).
///
/// These run inside the app (the test host) against a real `BrowserStore` and real `WKWebView`s
/// loading `FixtureServer` pages, but nothing is tapped: a test calls what a control would call and
/// awaits what the store reports. Nothing here reads the screen, so a loaded runner makes a test
/// slower, never wrong. What only the UI can show (gestures, menus, sheets, layout) stays in
/// CormorantUITests.
///
/// A test gets 5 minutes, the most one needs: erasing a deleted profile waits up to about two minutes
/// for WebKit to let go of its data, and a loaded runner can double the rest. Swift Testing takes the
/// shortest limit that applies, so a suite or test can lower it but not raise it.
@Suite(.serialized, .timeLimit(.minutes(5)))
@MainActor
struct AppTests {}

extension AppTests {
    /// The app knew it was hosting these tests: it built no browser of its own, so nothing here runs
    /// beside a live one (loading the app group's tabs, fetching filter lists, taking key window).
    @Suite("Test host")
    @MainActor
    struct TestHostTests {
        @Test func appKnowsItIsHostingTests() {
            #expect(CormorantApp.isHostingTests)
        }
    }
}
