import Testing

/// Every in-process test, one at a time. They share the app's main actor, WebKit's processes and its
/// website data stores, so two at once would see each other's pages and profiles. Each file adds its
/// suite as an extension, which `.serialized` reaches (it applies to nested suites too).
///
/// These run inside the app (the test host) against a real `BrowserStore` and real `WKWebView`s
/// loading `FixtureServer` pages, but nothing is tapped: a test calls what a control would call and
/// awaits what the store reports. Nothing here reads the screen, so a loaded runner makes a test
/// slower, never wrong. What only the UI can show (gestures, menus, sheets, layout) stays in
/// CormorantUITests.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct AppTests {}
