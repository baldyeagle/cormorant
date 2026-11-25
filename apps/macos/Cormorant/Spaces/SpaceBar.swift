import CormorantBrowser
import CormorantCore
import SwiftUI

/// A Space's icon in the sidebar's bottom row: a click switches to it, a right-click has its menu,
/// and Edit Space hangs off it.
struct SpaceButton: View {
    let space: Space
    /// Its place in the row, for its ⌃ number.
    let index: Int
    let store: BrowserStore
    let commands: WindowCommands
    let presentsEditor: Bool

    private var isActive: Bool { space.id == store.state.activeSpaceID }

    var body: some View {
        let spaceID = space.id
        Button {
            store.switchToSpace(space.id)
        } label: {
            Group {
                if isActive {
                    SpaceBadge(space: space, side: 20)
                } else {
                    Image(systemName: space.icon.rawValue)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(store.state.nameWithProfile(of: space))
        .accessibilityLabel(store.state.nameWithProfile(of: space))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            if !space.isIncognito { menu }
        }
        .popover(item: commands.spaceEditor({ $0 == .edit(spaceID) }, presents: presentsEditor), arrowEdge: .top) { target in
            SpaceEditor(target: target, store: store, commands: commands)
        }
    }

    @ViewBuilder private var menu: some View {
        if !isActive {
            Button("Switch to \(space.name)") { store.switchToSpace(space.id) }
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control) : nil)
            Divider()
        }
        Button("Edit Space…") { commands.spaceEditor = .edit(space.id) }
        // Home can be neither.
        Group {
            Button("Archive Space…") { commands.spaceRemoval = SpaceRemoval(.archive, space, in: store.state) }
            Button("Delete Space…") { commands.spaceRemoval = SpaceRemoval(.delete, space, in: store.state) }
        }
        .disabled(space.id == Space.defaultID)
        Divider()
        Button("New Space…") { commands.spaceEditor = .new }
            .keyboardShortcut("n", modifiers: [.control, .shift])
    }
}

/// The bottom row's +, which New Space hangs off.
struct NewSpaceButton: View {
    let store: BrowserStore
    let commands: WindowCommands
    let presentsEditor: Bool

    var body: some View {
        IconButton("New Space", systemImage: "plus", help: "New Space ⌃⇧N") { commands.spaceEditor = .new }
            .popover(item: commands.spaceEditor({ $0 == .new }, presents: presentsEditor), arrowEdge: .top) { target in
                SpaceEditor(target: target, store: store, commands: commands)
            }
    }
}
