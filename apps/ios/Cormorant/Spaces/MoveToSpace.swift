import CormorantCore
import SwiftUI

/// Move to Space as a submenu: a switcher card's long-press menu. Every Space, the tab's own checked
/// and disabled; one on another profile says it reloads.
struct MoveToSpaceMenu: View {
    @Environment(BrowserStore.self) private var store
    let tabID: UUID
    /// Runs the move, so the caller can animate it.
    let onMove: (UUID) -> Void

    var body: some View {
        Menu {
            // Toggles and buttons of an image and two texts: a menu drops the subtitle inside a Label.
            ForEach(store.moveDestinations(for: tabID)) { destination in
                if destination.isCurrent {
                    Toggle(isOn: .constant(true)) { label(destination) }
                        .disabled(true)
                } else {
                    Button { onMove(destination.space.id) } label: { label(destination) }
                }
            }
        } label: {
            Label("Move to Space", systemImage: "arrow.up.forward.square")
        }
    }

    @ViewBuilder private func label(_ destination: MoveDestination) -> some View {
        Image(uiImage: SpaceBadge.menuImage(for: destination.space)).renderingMode(.original)
        Text(destination.space.name)
        Text(destination.subtitle)
    }
}

/// Move to Space as a sheet: from the caret sheet's row, and a toast's Move…. Choosing a Space moves
/// the tab at once and calls `onMoved`; the store's toast offers Undo.
struct MoveToSpaceSheet: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tabID: UUID
    let onMoved: () -> Void
    /// Set by the first choice: a second tap while the sheet goes does nothing.
    @State private var hasMoved = false

    var body: some View {
        let destinations = store.moveDestinations(for: tabID)
        NavigationStack {
            List {
                Section {
                    ForEach(destinations) { destination in
                        Button {
                            guard !hasMoved else { return }
                            hasMoved = true
                            store.moveTab(tabID, toSpace: destination.space.id)
                            onMoved()
                        } label: {
                            MoveDestinationRow(destination: destination)
                        }
                        .disabled(destination.isCurrent)
                        .accessibilityLabel(destination.space.name)
                        .accessibilityValue(destination.subtitle)
                        .accessibilityAddTraits(destination.isCurrent ? .isSelected : [])
                        .accessibilityIdentifier("MoveDestination")
                    }
                } footer: {
                    if destinations.contains(where: \.changesProfile) {
                        Text("Spaces marked Reloads use another profile, so the page loads again there.")
                    }
                }
            }
            .navigationTitle("Move to Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The tab closed, or there's no longer a Space to move it to. Not once it has moved: the sheet
        // is going already.
        .onChange(of: destinations.isEmpty) { _, empty in if empty, !hasMoved { dismiss() } }
    }
}

/// The Space's badge, its name and `MoveDestination.subtitle`, a check on the tab's own.
private struct MoveDestinationRow: View {
    let destination: MoveDestination
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 30

    var body: some View {
        HStack(spacing: 14) {
            SpaceIconBadge(icon: destination.space.icon, color: destination.space.color, side: min(badge, 48))
            VStack(alignment: .leading, spacing: 2) {
                // Colors, not the hierarchical styles: in a list's button those take the tint.
                Text(destination.space.name)
                    .foregroundStyle(destination.isCurrent ? Color.secondary : Color.primary)
                HStack(spacing: 4) {
                    if destination.changesProfile {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    Text(destination.subtitle)
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if destination.isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}
