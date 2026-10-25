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
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var dragOffset: CGFloat = 0

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
        .onTapGesture(perform: onOpen)
        .simultaneousGesture(swipeToClose)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(tab.url?.displayString ?? "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens this tab")
        // Explicit, or the merged Close button's action would be the default one.
        .accessibilityAction { onOpen() }
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
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
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

    @ViewBuilder
    private var preview: some View {
        if let snapshot {
            // The overlay keeps the filled image from sizing the card (it would push the header out).
            Color.clear.overlay(alignment: .top) {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, alignment: .top)
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

    /// Vertical-only so horizontal drags still scroll the stack.
    private var swipeToClose: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = min(0, value.translation.height)
            }
            .onEnded { value in
                let flung = value.predictedEndTranslation.height < -Self.closeDistance * 3
                if dragOffset < -Self.closeDistance || (dragOffset < 0 && flung) {
                    // Closed as the finger lifts: the removal transition carries the card on from here
                    // while its neighbors close the gap.
                    onClose()
                } else {
                    withAnimation(.snappy(duration: 0.3)) { dragOffset = 0 }
                }
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
