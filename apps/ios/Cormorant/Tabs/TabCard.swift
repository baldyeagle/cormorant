import CormorantCore
import SwiftUI

/// One tab in the switcher: title, host, and a snapshot (or a tinted placeholder). Swipe up to close.
struct TabCard: View {
    let tab: CormorantCore.Tab
    let snapshot: UIImage?
    let isActive: Bool
    let size: CGSize
    let onClose: () -> Void

    @State private var dragOffset: CGFloat = 0

    private static let closeDistance: CGFloat = 120
    private var host: String { tab.url?.displayHost ?? "" }

    var body: some View {
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
        .offset(y: dragOffset)
        .opacity(size.height > 0 ? 1 - min(1, -dragOffset / size.height) * 0.7 : 1)
        .contentShape(.rect)
        .simultaneousGesture(swipeToClose)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Close", onClose)
    }

    private var header: some View {
        // Close sits on the leading edge: the next card in the stack overlaps this one's trailing side.
        HStack(alignment: .top, spacing: 8) {
            Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .imageScale(.large)
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !host.isEmpty {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
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
                    withAnimation(.easeIn(duration: 0.18)) {
                        dragOffset = -size.height * 1.5
                    } completion: {
                        onClose()
                    }
                } else {
                    withAnimation(.spring) { dragOffset = 0 }
                }
            }
    }
}
