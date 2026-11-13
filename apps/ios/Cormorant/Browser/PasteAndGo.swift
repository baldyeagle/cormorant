import UIKit

/// Paste and Go / Paste and Search in the search field's edit menu, as Safari's address field has.
///
/// SwiftUI's `TextField` has no way to add to its edit menu, but UIKit builds the menu up the
/// responder chain and the window scene is on it, so `UIWindowScene` (below) adds the item and
/// takes its action. The actions are UIKit's standard `pasteAndGo:` and `pasteAndSearch:`, which
/// the system draws as its own paste items (with its own titles), so reading what another app
/// copied doesn't ask permission, as reading it unprompted would.
///
/// One item, named for what's on the pasteboard: Go for a link or text that looks like an address,
/// Search for other text. Either way the text is submitted as if typed, so the address resolver
/// decides what loads, as it does for Go on the keyboard; the system's guess only names the item.
/// It's made without reading the text (which would ask permission), by the system's pattern
/// detection, run as the panel opens, when the app comes back (where most copying happens) and
/// when the app itself copies. Not by `changeCount`: it moves without a copy, as the keyboard
/// comes up (on the iOS 27.1 simulator at least).
@MainActor
enum PasteAndGo {
    struct Target {
        /// The panel that set it. One closing as the next opens (it leaves with a transition) mustn't
        /// clear the new one's.
        let owner: UUID
        /// Submits the pasted text as if typed.
        let submit: (String) -> Void
    }

    /// The search panel, while it's up and not searching tabs only. Web pages' fields never get the item.
    static var target: Target? {
        didSet {
            guard target != nil else { return }
            observe()
            detect()
        }
    }

    /// Clears `target` if `owner` set it.
    static func release(_ owner: UUID) {
        if target?.owner == owner { target = nil }
    }

    /// Whether the pasteboard's text looked like an address when last checked.
    private static var textIsAddress = false
    /// Counts detections, so an answer that arrives after a newer one started is dropped.
    private static var detections = 0
    private static var observers: [NSObjectProtocol] = []

    /// The item for the search field's edit menu, or nil when the panel isn't up or there's nothing to paste.
    static var command: UICommand? {
        let pasteboard = UIPasteboard.general
        guard target != nil, pasteboard.hasStrings || pasteboard.hasURLs else { return nil }
        return pasteboard.hasURLs || textIsAddress
            ? UICommand(title: "Paste and Go", action: #selector(UIResponderStandardEditActions.pasteAndGo(_:)))
            : UICommand(title: "Paste and Search", action: #selector(UIResponderStandardEditActions.pasteAndSearch(_:)))
    }

    static func paste() {
        guard let target, let text = pastedText() else { return }
        target.submit(text)
    }

    /// The pasteboard's link or text on one line, or nil when there's nothing to load.
    private static func pastedText() -> String? {
        let pasteboard = UIPasteboard.general
        guard let raw = pasteboard.url?.absoluteString ?? pasteboard.string else { return nil }
        let text = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func observe() {
        guard observers.isEmpty else { return }
        for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if target != nil { detect() } }
            })
        }
    }

    private static func detect() {
        detections += 1
        let detection = detections
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings else {
            textIsAddress = false
            return
        }
        // The completion-handler form: the async one never returned on the iOS 27.1 simulator.
        pasteboard.detectPatterns(for: [\.probableWebURL]) { @Sendable result in
            let isAddress = (try? result.get())?.contains(\.probableWebURL) ?? false
            Task { @MainActor in
                guard detection == detections else { return }
                textIsAddress = isAddress
            }
        }
    }
}

extension UIWindowScene {
    /// Adds Paste and Go or Paste and Search at the end of the search field's edit menu, after
    /// AutoFill, where Safari has it. Neither `UIWindowScene` nor `UIScene` implements this or the
    /// two actions, so nothing of UIKit's is replaced. (It does implement `canPerformAction`: leave
    /// that alone.)
    override open func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, builder.menu(for: .standardEdit) != nil,
              let command = PasteAndGo.command else { return }
        builder.insertChild(UIMenu(options: .displayInline, children: [command]), atEndOfMenu: .root)
    }

    override open func pasteAndGo(_ sender: Any?) { PasteAndGo.paste() }

    override open func pasteAndSearch(_ sender: Any?) { PasteAndGo.paste() }
}
