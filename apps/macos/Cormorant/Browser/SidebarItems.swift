import AppKit
import CormorantBrowser
import CormorantCore
import SwiftUI

/// What the sidebar is renaming or choosing an icon for, one at a time.
@Observable
final class SidebarEditor {
    /// A tab or folder whose name is being edited.
    var renaming: UUID?
    /// A folder whose icon is being chosen.
    var pickingIcon: UUID?
}

/// What a sidebar row needs to know about the Space it's in.
struct SidebarContext {
    let store: BrowserStore
    let editor: SidebarEditor
    /// The tab the Space shows, highlighted, unless a new tab is being composed.
    let shownTabID: UUID?
}

/// The tile pins, three to a row.
struct TileGrid: View {
    let tiles: [CormorantCore.Tab]
    let context: SidebarContext

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
            ForEach(tiles) { tab in
                Tile(tab: tab, context: context)
            }
        }
    }
}

private struct Tile: View {
    let tab: CormorantCore.Tab
    let context: SidebarContext
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let store = context.store
        let isShown = tab.id == context.shownTabID
        Favicon(url: tab.pinnedURL ?? tab.url, store: store, size: 20)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(background(isShown: isShown), in: .rect(cornerRadius: 10))
            .shadow(color: isShown && colorScheme == .light ? .black.opacity(0.12) : .clear, radius: 1.5, y: 1)
            .overlay(alignment: .topTrailing) {
                if tab.isAwayFromPin {
                    Text("/")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                        .padding(.trailing, 6)
                }
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { store.activate(tab.id) }
            .help(tab.pinName)
            .accessibilityElement()
            .accessibilityLabel(tab.pinName)
            .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
            .popover(isPresented: context.editor.binding(renaming: tab.id), arrowEdge: .bottom) {
                NameField(name: tab.pinName) { store.rename(tab.id, to: $0) } done: { context.editor.renaming = nil }
                    .padding(10)
                    .frame(width: 220)
            }
            .contextMenu { TabMenu(tab: tab, context: context) }
    }

    private func background(isShown: Bool) -> Color {
        let dark = colorScheme == .dark
        if isShown { return dark ? .white.opacity(0.16) : .white }
        return dark ? .white.opacity(hovering ? 0.1 : 0.06) : .white.opacity(hovering ? 0.75 : 0.5)
    }
}

/// A tab, or a folder with its tabs under it when open.
struct SidebarItemRows: View {
    let item: SidebarItem
    let context: SidebarContext

    var body: some View {
        switch item {
        case .tab(let tab):
            TabRow(tab: tab, context: context, indented: false)
        case .folder(let folder, let tabs):
            FolderRow(folder: folder, tabs: tabs, context: context)
            if folder.isOpen {
                ForEach(tabs) { tab in
                    TabRow(tab: tab, context: context, indented: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

private struct FolderRow: View {
    let folder: Folder
    let tabs: [CormorantCore.Tab]
    let context: SidebarContext
    @State private var hovering = false

    var body: some View {
        let store = context.store
        let editor = context.editor
        // Closed on the tab on screen, the folder shows that it holds it.
        let holdsShown = !folder.isOpen && tabs.contains { $0.id == context.shownTabID }
        HStack(spacing: 9) {
            FolderGlyph(icon: folder.icon, isOpen: folder.isOpen)
            if editor.renaming == folder.id {
                NameField(name: folder.name) { store.renameFolder(folder.id, to: $0) } done: { editor.renaming = nil }
            } else {
                Text(folder.name).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .rowStyle(isActive: holdsShown, hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture {
            guard editor.renaming != folder.id else { return }
            withAnimation(.snappy(duration: 0.22)) { store.setFolderOpen(folder.id, !folder.isOpen) }
        }
        .accessibilityElement(children: editor.renaming == folder.id ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(folder.isOpen ? "Open" : "Closed")
        .popover(isPresented: editor.binding(pickingIcon: folder.id), arrowEdge: .trailing) {
            IconPicker(selected: folder.icon) { icon in
                store.setFolderIcon(folder.id, icon)
                editor.pickingIcon = nil
            }
        }
        .contextMenu {
            Button("Rename…") { editor.renaming = folder.id }
            Button("Icon…") { editor.pickingIcon = folder.id }
            Divider()
            let pinned = store.state.isPinnedFolder(folder.id)
            Button(pinned ? "Unpin Folder" : "Pin Folder") {
                withAnimation(.snappy(duration: 0.22)) { store.moveFolder(folder.id, toPinned: !pinned) }
            }
            Button("Ungroup") { store.ungroupFolder(folder.id) }
            Divider()
            Button(tabs.count == 1 ? "Close Folder and Its Tab" : "Close Folder and Its \(tabs.count) Tabs") {
                store.closeFolder(folder.id)
            }
        }
    }
}

/// A folder, closed or open, with its symbol drawn on it in the Space's color.
struct FolderGlyph: View {
    let icon: String?
    let isOpen: Bool
    @Environment(\.spaceTint) private var tint

    var body: some View {
        ZStack {
            if isOpen {
                OpenFolderBack().fill(tint.opacity(0.55))
                OpenFolderFront().fill(tint)
            } else {
                ClosedFolder().fill(tint)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: isOpen ? 0.6 : 0, y: isOpen ? 2.2 : 1.4)
            }
        }
        .frame(width: 18, height: 15)
        .animation(.snappy(duration: 0.22), value: isOpen)
        .accessibilityHidden(true)
    }
}

/// The folder shapes, on an 18 × 15 grid.
private nonisolated struct ClosedFolder: Shape {
    func path(in rect: CGRect) -> Path {
        scaled(rect) { path in
            path.move(to: CGPoint(x: 1, y: 3))
            path.addQuadCurve(to: CGPoint(x: 3, y: 1), control: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 6.6, y: 1))
            path.addLine(to: CGPoint(x: 8.4, y: 2.8))
            path.addLine(to: CGPoint(x: 15, y: 2.8))
            path.addQuadCurve(to: CGPoint(x: 17, y: 4.8), control: CGPoint(x: 17, y: 2.8))
            path.addLine(to: CGPoint(x: 17, y: 12))
            path.addQuadCurve(to: CGPoint(x: 15, y: 14), control: CGPoint(x: 17, y: 14))
            path.addLine(to: CGPoint(x: 3, y: 14))
            path.addQuadCurve(to: CGPoint(x: 1, y: 12), control: CGPoint(x: 1, y: 14))
            path.closeSubpath()
        }
    }
}

private nonisolated struct OpenFolderBack: Shape {
    func path(in rect: CGRect) -> Path {
        scaled(rect) { path in
            path.move(to: CGPoint(x: 1, y: 3))
            path.addQuadCurve(to: CGPoint(x: 3, y: 1), control: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 6.6, y: 1))
            path.addLine(to: CGPoint(x: 8.4, y: 2.8))
            path.addLine(to: CGPoint(x: 15, y: 2.8))
            path.addQuadCurve(to: CGPoint(x: 17, y: 4.8), control: CGPoint(x: 17, y: 2.8))
            path.addLine(to: CGPoint(x: 17, y: 5.6))
            path.addLine(to: CGPoint(x: 5.2, y: 5.6))
            path.addLine(to: CGPoint(x: 1, y: 12))
            path.closeSubpath()
        }
    }
}

private nonisolated struct OpenFolderFront: Shape {
    func path(in rect: CGRect) -> Path {
        scaled(rect) { path in
            path.move(to: CGPoint(x: 3.6, y: 6.4))
            path.addQuadCurve(to: CGPoint(x: 5.2, y: 5.4), control: CGPoint(x: 4.1, y: 5.4))
            path.addLine(to: CGPoint(x: 17, y: 5.4))
            path.addLine(to: CGPoint(x: 15, y: 12.6))
            path.addQuadCurve(to: CGPoint(x: 13.2, y: 14), control: CGPoint(x: 14.7, y: 14))
            path.addLine(to: CGPoint(x: 1.6, y: 14))
            path.closeSubpath()
        }
    }
}

private nonisolated func scaled(_ rect: CGRect, _ build: (inout Path) -> Void) -> Path {
    var path = Path()
    build(&path)
    return path.applying(CGAffineTransform(scaleX: rect.width / 18, y: rect.height / 15)
        .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
}

/// The symbols a folder can wear, and none.
private struct IconPicker: View {
    let selected: String?
    let choose: (String?) -> Void
    @Environment(\.spaceTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Icon").font(.headline)
                Spacer()
                Button("Plain Folder") { choose(nil) }
                    .buttonStyle(.link)
                    .disabled(selected == nil)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(Folder.icons, id: \.self) { icon in
                    Button {
                        choose(icon)
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(icon == selected ? tint : .primary)
                            .background(icon == selected ? tint.opacity(0.18) : .clear, in: .rect(cornerRadius: 7))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(icon)
                }
            }
        }
        .padding(12)
    }
}

/// A name being edited in place: Return keeps it, Escape or clicking away leaves it as it was.
struct NameField: View {
    let name: String
    let save: (String) -> Void
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = name
                // After the menu that asked for it has closed, or the focus doesn't take.
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit {
                save(text)
                done()
            }
            .onExitCommand { done() }
            .onChange(of: focused) { _, isFocused in if !isFocused { done() } }
    }
}

/// What can be done with a tab from its row or tile.
struct TabMenu: View {
    let tab: CormorantCore.Tab
    let context: SidebarContext

    var body: some View {
        let store = context.store
        if tab.isAwayFromPin {
            Button("Back to Pinned Page") { store.backToPinnedPage(tab.id) }
        }
        Button("Rename…") { context.editor.renaming = tab.id }
        Divider()
        if tab.isPinned {
            if tab.pinPlace == .tile {
                Button("Move to Pinned List") { store.movePin(tab.id, to: .list) }
            } else {
                Button("Move to Tiles") { store.movePin(tab.id, to: .tile) }
            }
            Button("Unpin") { store.unpin(tab.id) }
        } else if store.canPin(tab.id) {
            Button("Pin") { store.pin(tab.id, place: .list) }
            Button("Pin as Tile") { store.pin(tab.id, place: .tile) }
        }
        if tab.pinPlace != .tile || !tab.isPinned, !tab.isIncognito {
            Menu("Add to Folder") {
                ForEach(store.folders(for: tab.id)) { folder in
                    Button(folder.name) { withAnimation(.snappy(duration: 0.22)) { store.addToFolder(tab.id, folder.id) } }
                }
                if !store.folders(for: tab.id).isEmpty { Divider() }
                Button("New Folder…") {
                    if let folderID = store.newFolder(with: tab.id) { context.editor.renaming = folderID }
                }
            }
        }
        if tab.folderID != nil {
            Button("Remove from Folder") { withAnimation(.snappy(duration: 0.22)) { store.removeFromFolder(tab.id) } }
        }
        let destinations = store.moveDestinations(for: tab.id).filter { !$0.isCurrent }
        if !destinations.isEmpty {
            Menu("Move to Space") {
                ForEach(destinations) { destination in
                    Button {
                        store.moveTab(tab.id, toSpace: destination.space.id)
                    } label: {
                        Image(nsImage: SpaceBadge.menuImage(for: destination.space))
                        Text(destination.space.name)
                        Text(destination.subtitle)
                    }
                }
            }
        }
        Divider()
        Button("Close Tab") { store.close(tab.id) }
    }
}

extension SidebarEditor {
    func binding(renaming id: UUID) -> Binding<Bool> {
        Binding(get: { self.renaming == id }, set: { if !$0, self.renaming == id { self.renaming = nil } })
    }

    func binding(pickingIcon id: UUID) -> Binding<Bool> {
        Binding(get: { self.pickingIcon == id }, set: { if !$0, self.pickingIcon == id { self.pickingIcon = nil } })
    }
}

/// The active Space's color, for what the sidebar draws in it.
extension EnvironmentValues {
    @Entry var spaceTint: Color = .accentColor
}
