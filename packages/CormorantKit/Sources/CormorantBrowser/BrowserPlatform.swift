import CormorantCore
import Foundation
import WebKit

/// What the app the engine runs in provides.
public protocol BrowserPlatform: AnyObject {
    /// Applied to every tab's web view configuration, and to anything that may become a tab's.
    func configure(_ configuration: WKWebViewConfiguration)

    /// Made with the tab's session, before the session becomes its web view's delegate and before it
    /// has a chrome: read its web view, nothing that reaches the chrome. The web view has a page in it
    /// already when the tab adopts a link preview's.
    func makeChrome(for session: TabSession, in store: BrowserStore) -> any TabChrome

    func announce(_ message: String)
    var toastLifetime: Duration { get }
    var canAddPasses: Bool { get }

    func keepRunning(until task: Task<Void, Never>, named name: String)

    /// A tab is about to load in the background from `opener`: stage it where and at the size `opener`
    /// is, so it needs no relayout once shown.
    func prepareStage(from opener: WKWebView)
    /// Without a stage, a tab opened in the background waits to load until it's shown, and one that
    /// adopted a link preview's page is pictured for the switcher only once shown.
    var canStage: Bool { get }
    func stage(_ webView: WKWebView)
    func unstage(_ webView: WKWebView)
}

/// A tab's own part of the app: what its web view gets on this platform (gestures, menus, dialogs).
/// If it's a `WKUIDelegate` too, it gets the UI delegate methods the engine doesn't implement, such
/// as the iPhone's link menu or the Mac's file picker.
public protocol TabChrome: AnyObject {
    /// Returns false if it couldn't; the caller then answers the dialog itself.
    func present(_ dialog: PageDialog) -> Bool

    /// The web view's under-page color as it looks now, or nil if it can't be read as a color. When
    /// the appearance changes, call the session's `pageBackgroundDidChange()`: a page can restyle for
    /// it without WebKit's under-page color changing.
    func pageBackground() -> PageBackground?

    /// Whether this click on a link opens it in a new tab rather than here (on a Mac, ⌘-click),
    /// and how; nil to follow it in this tab.
    func newTab(for click: WKNavigationAction) -> NewTabRequest?

    func tabDidBecomeActive()
    func tabDidResignActive()
    func sessionDidDetach()
}

/// A link click to open in a new tab instead of here.
public struct NewTabRequest: Equatable, Sendable {
    public let inBackground: Bool

    public init(inBackground: Bool) {
        self.inBackground = inBackground
    }
}

public struct PageBackground: Equatable {
    public let color: CormorantCore.RGBColor
    /// The appearance it was read in: a page's colors can follow it.
    public let appearance: Appearance

    public init(color: CormorantCore.RGBColor, appearance: Appearance) {
        self.color = color
        self.appearance = appearance
    }
}

/// Once presented, its `done` (where it has one) is called exactly once.
public enum PageDialog {
    case alert(title: String?, message: String, done: @MainActor () -> Void)
    case confirm(title: String?, message: String, done: @MainActor (Bool) -> Void)
    /// `done` gets nil for Cancel.
    case prompt(title: String?, message: String, defaultText: String?, done: @MainActor (String?) -> Void)
    /// A link to another app (`mailto:`, `tel:`), opened only if the user says Open.
    case openInOtherApp(URL, appName: String)
}
