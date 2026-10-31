#if DEBUG
import SwiftUI
import UIKit

/// UI tests only (`-uiTesting`): invisible elements whose accessibility values report state a test
/// can't see on screen, so it can wait for that state instead of guessing a delay. Each value is
/// worked out when XCTest reads it; nothing redraws or runs on a timer.
/// - `UITesting.saves`: "settled" once everything the app writes while browsing is on disk, else
///   "pending" (`BrowserStore.hasUnsavedWork`).
/// - `UITesting.pasteboard`: the link or text the app last copied, while the pasteboard still holds
///   it (`OwnPasteboardWrite`). The test runner reading the pasteboard itself would be a cross-app
///   paste, which asks for permission, and so would the app reading anything another app (or the
///   Mac's clipboard, synced into the Simulator) put there.
/// - `UITesting.pull`: how the last drag on a page went (`PullToRefresh.lastPullOutcome`): "moving",
///   then "committed" or "dropped <moves>"; "none" before any drag.
struct UITestingProbes: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            Probe(identifier: "UITesting.saves") { [store] in store.hasUnsavedWork ? "pending" : "settled" }
            Probe(identifier: "UITesting.pasteboard") {
                let pasteboard = UIPasteboard.general
                // `changeCount` never asks; the contents only once it's known to be the app's own.
                guard pasteboard.changeCount == OwnPasteboardWrite.changeCount else { return nil }
                return pasteboard.url?.absoluteString ?? pasteboard.string
            }
            Probe(identifier: "UITesting.pull") { PullToRefresh.lastPull?.lastPullOutcome ?? "none" }
        }
        .allowsHitTesting(false)
    }
}

/// The pasteboard's change count just after the app's own last write, so `UITestingProbes` reads only
/// what the app put there.
enum OwnPasteboardWrite {
    private(set) static var changeCount: Int?

    static func record() { changeCount = UIPasteboard.general.changeCount }
}

private struct Probe: UIViewRepresentable {
    let identifier: String
    let value: () -> String?

    func makeUIView(context: Context) -> ProbeView { ProbeView(identifier: identifier, value: value) }

    func updateUIView(_ view: ProbeView, context: Context) { view.value = value }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ProbeView, context: Context) -> CGSize? {
        CGSize(width: 1, height: 1)
    }

    final class ProbeView: UIView {
        var value: () -> String?

        init(identifier: String, value: @escaping () -> String?) {
            self.value = value
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = identifier
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var accessibilityValue: String? {
            get { value() }
            set {}
        }
    }
}
#endif
