#if DEBUG
import CormorantCore
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
/// - `UITesting.toasts`: how many toasts have been put up since launch, then "up" or "none", so a test
///   can see one come and go without having to catch it on screen.
/// - `UITesting.erasing`: how many deleted profiles' website data and history are still to be
///   erased (`BrowserState.profilesToErase`): "0" once a deleted profile's data is gone.
/// - `UITesting.focus`: the name of the Space the Focus filter sends links to, or "off" (set by
///   `cormorant://ui-testing/focus`).
/// - `UITesting.stripFade`: which edges of the switcher's Space strip fade out, with Spaces beyond them
///   (`SpaceStrip.reportedOverflow`): "none", "leading", "trailing" or "both"; "no scrolling" while no
///   strip scrolls.
/// - `UITesting.keyboard`: "up" from the keyboard's did-show to its did-hide, else "down". The bar's
///   buttons come back to the accessibility tree as the keyboard starts down, and the keyboard leaves
///   the tree then too, but it takes taps over the bar until it has slid away.
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
            Probe(identifier: "UITesting.keyboard") { KeyboardPresence.isUp ? "up" : "down" }
            Probe(identifier: "UITesting.erasing") { [store] in "\(store.state.profilesToErase.count)" }
            Probe(identifier: "UITesting.toasts") { [store] in "\(store.toastsShown) \(store.toast == nil ? "none" : "up")" }
            Probe(identifier: "UITesting.focus") { [store] in
                store.focusFilter.spaceID.map { id in store.state.space(id)?.name ?? "unknown" } ?? "off"
            }
            Probe(identifier: "UITesting.stripFade") {
                guard let overflow = SpaceStrip.reportedOverflow else { return "no scrolling" }
                return switch (overflow.leading, overflow.trailing) {
                case (true, true): "both"
                case (true, false): "leading"
                case (false, true): "trailing"
                case (false, false): "none"
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Whether the keyboard is on screen, by its did-show and did-hide notifications, for `UITestingProbes`.
/// Started at launch (`CormorantApp.init`), before the first keyboard.
enum KeyboardPresence {
    private(set) static var isUp = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { isUp = true }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { isUp = false }
            },
        ]
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
/// `-uiTestingShowTouches` (with `-uiTesting`): a red dot wherever a touch reaches the app's windows,
/// fading over a second, so a test's screen recording shows its taps and drags. A tap that never
/// reaches the app (taken by the keyboard, say) leaves no dot.
enum TouchMarks {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { watchEveryWindow() }
        }
    }

    private static func watchEveryWindow() {
        let windows = UIApplication.shared.connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is Recognizer }) {
            window.addGestureRecognizer(Recognizer())
        }
    }

    /// Sees every touch in its window and never takes one.
    private final class Recognizer: UIGestureRecognizer {
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { mark(touch) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { mark(touch, size: 14) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        private func mark(_ touch: UITouch, size: CGFloat = 36) {
            guard let window = view as? UIWindow else { return }
            let dot = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            dot.center = touch.location(in: window)
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = UIColor.systemRed.withAlphaComponent(0.55)
            dot.layer.borderColor = UIColor.white.cgColor
            dot.layer.borderWidth = 2
            dot.isUserInteractionEnabled = false
            window.addSubview(dot)
            UIView.animate(withDuration: 1, delay: 0.3, options: [.allowUserInteraction]) { dot.alpha = 0 }
                completion: { _ in dot.removeFromSuperview() }
        }
    }
}
#endif
