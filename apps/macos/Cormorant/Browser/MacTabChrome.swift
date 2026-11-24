import AppKit
import CormorantBrowser
import CormorantCore
import WebKit

/// A tab's Mac side: the page's dialogs as sheets on its window, and the file picker.
final class MacTabChrome: NSObject, TabChrome, WKUIDelegate {
    private weak var session: TabSession?
    private let webView: WKWebView
    private var appearanceObservation: NSKeyValueObservation?

    init(session: TabSession) {
        self.session = session
        webView = session.webView
        super.init()
        appearanceObservation = webView.observe(\.effectiveAppearance) { [weak session] _, _ in
            MainActor.assumeIsolated { session?.pageBackgroundDidChange() }
        }
    }

    /// False when the tab isn't in a window or a sheet is up on it already.
    func present(_ dialog: PageDialog) -> Bool {
        guard let window = webView.window, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        switch dialog {
        case .alert(let title, let message, let done):
            alert.setText(title: title, message: message)
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in done() }
        case .confirm(let title, let message, let done):
            alert.setText(title: title, message: message)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
        case .prompt(let title, let message, let defaultText, let done):
            alert.setText(title: title, message: message)
            let field = NSTextField(string: defaultText ?? "")
            field.frame.size.width = 260
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
        case .openInOtherApp(let url, let appName):
            alert.messageText = "Open in \(appName)?"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) {
                if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        }
        return true
    }

    func pageBackground() -> PageBackground? {
        let appearance = webView.effectiveAppearance
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            color = webView.underPageBackgroundColor.usingColorSpace(.sRGB)
        }
        guard let color else { return nil }
        return PageBackground(
            color: RGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                            alpha: color.alphaComponent),
            appearance: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
    }

    func tabDidBecomeActive() {}
    func tabDidResignActive() {}
    func sessionDidDetach() {}

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
}

private extension NSAlert {
    /// A page's dialog is titled with its site, when it has one.
    func setText(title: String?, message: String) {
        messageText = title ?? message
        informativeText = title == nil ? "" : message
    }
}
