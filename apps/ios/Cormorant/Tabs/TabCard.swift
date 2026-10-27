import CormorantCore
import SwiftUI

/// One tab in the switcher: favicon and title above the card, then the address and a snapshot (or a
/// tinted placeholder). Swipe up to close.
struct TabCard: View {
    let tab: CormorantCore.Tab
    let snapshot: UIImage?
    let favicons: FaviconStore
    let isActive: Bool
    /// The card itself, not counting the label above it.
    let size: CGSize
    /// How much of the label the next card's label leaves room for.
    let labelWidth: CGFloat
    /// Passed the page preview's place on screen, for the open animation to grow from: centered where
    /// the fan draws it, at its untilted, unscaled size.
    let onOpen: (CGRect) -> Void
    let onClose: () -> Void

    @State private var dragOffset: CGFloat = 0
    /// Not observed: it changes on every frame of a scroll, and only a tap reads it.
    @State private var previewFrame = FrameBox()

    private static let closeDistance: CGFloat = 120
    private var host: String { tab.url?.displayHost ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            card
        }
        .offset(y: dragOffset)
        .opacity(size.height > 0 ? 1 - min(1, -dragOffset / size.height) * 0.7 : 1)
        .contentShape(.rect)
        .onTapGesture { onOpen(previewFrame.rect) }
        .gesture(SwipeUpGesture(onChanged: { dragOffset = min(0, $0) }, onEnded: swipeEnded))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(tab.url?.displayString ?? "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens this tab")
        // Explicit, or the merged Close button's action would be the default one.
        .accessibilityAction { onOpen(previewFrame.rect) }
        .accessibilityAction(named: "Close", onClose)
    }

    private var label: some View {
        HStack(spacing: 6) {
            FaviconView(favicons: favicons, url: tab.url, host: host)
            Text(tab.displayTitle)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .frame(width: labelWidth, alignment: .leading)
        .padding(.leading, 2)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TabPreview(snapshot: snapshot, host: host, width: size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .onGeometryChange(for: CGRect.self) { proxy in
                    // The global frame takes in the fan's tilt and scale: it's the drawn preview's bounding
                    // box, whose center is the preview's.
                    let drawn = proxy.frame(in: .global)
                    return CGRect(x: drawn.midX - proxy.size.width / 2, y: drawn.midY - proxy.size.height / 2,
                                  width: proxy.size.width, height: proxy.size.height)
                } action: { previewFrame.rect = $0 }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var header: some View {
        // Close sits on the leading edge: the next card in the stack overlaps this one's trailing side.
        HStack(spacing: 6) {
            Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .imageScale(.large)
                .buttonStyle(.borderless)
            Text(tab.url?.displayString ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func swipeEnded(translation: CGFloat, velocity: CGFloat) {
        // Where a flick would coast to at UIScrollView's normal deceleration (0.998 per ms), as
        // DragGesture's predictedEndTranslation projected it.
        let flung = translation + velocity * 0.5 < -Self.closeDistance * 3
        if translation < -Self.closeDistance || (translation < 0 && flung) {
            // Closed as the finger lifts: the removal transition carries the card on from here
            // while its neighbors close the gap.
            onClose()
        } else {
            withAnimation(.snappy(duration: 0.3)) { dragOffset = 0 }
        }
    }
}

/// A tab's page as the card shows it: the snapshot pinned to the top at `width`, or the host on its
/// tint. Also what grows to fill the screen when a card opens.
struct TabPreview: View {
    let snapshot: UIImage?
    let host: String
    let width: CGFloat

    var body: some View {
        if let snapshot {
            // The overlay keeps the filled image from sizing the view (it would push the card's header out).
            Color.clear.overlay(alignment: .top) {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, alignment: .top)
            }
        } else {
            ZStack {
                HostTint.color(for: host).opacity(0.35)
                Text(host.isEmpty ? "New Tab" : host)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

private final class FrameBox {
    var rect: CGRect = .zero
}

/// Swipe up to close, in UIKit so it can decline horizontal drags before they start. A SwiftUI
/// `DragGesture` on the card, even a simultaneous one, kept the stack's scroll view from picking up
/// a quick horizontal flick: only slow drags scrolled.
private struct SwipeUpGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    // Measured in the window, not `pan.view`: that may be the scroll view, still coasting under the
    // finger.
    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: nil).y
        switch pan.state {
        // Began too: by then the finger has already moved past the pan's start threshold.
        case .began, .changed: onChanged(translation)
        case .ended: onEnded(translation, pan.velocity(in: nil).y)
        // Interrupted (a call, the switcher closing): settle back rather than close.
        case .cancelled, .failed: onEnded(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Starts only for a drag that's mostly upward; anything else fails at once and goes to the
        /// scroll view. Judged by the distance moved so far, which a slow drag's jittery velocity
        /// isn't.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let moved = pan.translation(in: nil)
            return moved.y < 0 && abs(moved.y) > abs(moved.x)
        }

        /// The stack holds still while a card is swiped away.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// A site's icon, or its initial on the host's tint until one arrives. Reads the store itself, so an
/// icon landing re-renders just this view.
private struct FaviconView: View {
    let favicons: FaviconStore
    let url: URL?
    let host: String

    var body: some View {
        Group {
            if let image = favicons.icon(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                HostTint.color(for: host)
                    .overlay {
                        Text(host.first.map { String($0).uppercased() } ?? "")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(.rect(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}
