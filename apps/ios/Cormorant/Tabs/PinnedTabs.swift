import CormorantBrowser
import CormorantCore
import SwiftUI

/// A pinned tab as a tile: its pinned site's icon on a rounded square, its name under it. Ringed in
/// the Space's color while it's the tab on screen; a slash badge once it has left its pinned page (as
/// Arc's slash before the title).
struct PinTile: View {
    let tab: CormorantCore.Tab
    let favicons: FaviconStore
    let isActive: Bool
    let accent: Color
    @ScaledMetric(relativeTo: .caption) private var scaledSide: CGFloat = 60

    /// Grows with the text size, to a point: past it the row would show only two.
    private var side: CGFloat { min(scaledSide, 84) }
    private var radius: CGFloat { side * 0.28 }

    var body: some View {
        let url = tab.pinnedURL ?? tab.url
        VStack(spacing: 6) {
            FaviconView(favicons: favicons, url: url, host: url?.displayHost ?? "", side: side * 0.46, backsDarkIcons: true)
                .frame(width: side, height: side)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                            .strokeBorder(accent, lineWidth: 2.5)
                            .padding(-4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if tab.isAwayFromPin { awayBadge }
                }
            Text(tab.pinName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: side + 10)
        }
        .contentShape(.rect)
    }

    private var awayBadge: some View {
        Text("/")
            .font(.system(size: side * 0.2, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: side * 0.32, height: side * 0.32)
            .background(Color(.secondarySystemGroupedBackground), in: .circle)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .offset(x: side * 0.1, y: -side * 0.1)
    }
}

extension CormorantCore.Tab {
    /// What VoiceOver says of a pin besides its name.
    func pinAccessibilityValue(isActive: Bool) -> String {
        var parts = ["Pinned"]
        if isActive { parts.append("on screen") }
        if isAwayFromPin { parts.append("away from its pinned page") }
        return parts.joined(separator: ", ")
    }
}

/// A pin's long-press menu: Back to Pinned Page (once it has left it), Rename, Move to Space (with
/// somewhere to go), Add to Folder, Remove from Folder (in one), Unpin, and Close, which leaves it pinned.
struct PinMenu: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: CormorantCore.Tab
    let onRename: () -> Void
    let onMove: (UUID) -> Void
    let onFolderPrompt: (FolderPrompt) -> Void
    let onClose: () -> Void

    var body: some View {
        if tab.isAwayFromPin {
            Button("Back to Pinned Page", systemImage: "arrow.uturn.backward") { store.backToPinnedPage(tab.id) }
        }
        Button("Rename…", systemImage: "pencil", action: onRename)
        if !store.moveDestinations(for: tab.id).isEmpty {
            MoveToSpaceMenu(tabID: tab.id, onMove: onMove)
        }
        AddToFolderMenu(tabID: tab.id, onPrompt: onFolderPrompt)
        if tab.folderID != nil {
            Button("Remove from Folder", systemImage: "folder.badge.minus") {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) {
                    store.removeFromFolder(tab.id)
                }
            }
        }
        Section {
            Button("Unpin", systemImage: "pin.slash") { store.unpin(tab.id) }
            Button("Close", systemImage: "xmark", role: .destructive, action: onClose)
        }
    }
}

/// Rename for a pin: an alert with its name, which an empty one clears back to its page's title.
struct RenamePinAlert: ViewModifier {
    @Environment(BrowserStore.self) private var store
    @Binding var tabID: UUID?
    @State private var name = ""
    @State private var pageTitle = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Pin", isPresented: Binding(get: { tabID != nil }, set: { if !$0 { tabID = nil } })) {
                // Its own name only: the page's title, shown as the placeholder, stays the page's to change.
                TextField(pageTitle, text: $name)
                    .accessibilityIdentifier("PinNameField")
                Button("Save") {
                    if let tabID { store.renamePin(tabID, to: name) }
                    tabID = nil
                }
                Button("Cancel", role: .cancel) { tabID = nil }
            } message: {
                Text("Leave it empty to use the page’s title.")
            }
            .onChange(of: tabID) { _, id in
                let tab = id.flatMap { store.state.tab($0) }
                name = tab?.customTitle ?? ""
                pageTitle = tab.map { $0.pinnedTitle ?? $0.pinnedURL?.host() ?? $0.displayTitle } ?? "Name"
            }
    }
}

/// The switcher's row of the Space's pins (`BrowserStore.pinRow`), above its cards: the tiles, then
/// the pinned list's pins as tiles and its folders as folder tiles. Tap a pin to open it, a folder to
/// open its panel; long-press either for its menu; drag a pin onto another to take its place.
struct PinnedRow: View {
    @Environment(BrowserStore.self) private var store
    let items: [SidebarItem]
    let accent: Color
    /// The tile's frame on screen, for the card that grows from it.
    let onOpen: (CormorantCore.Tab, CGRect) -> Void
    /// The folder tile's frame on screen, for the panel that grows from it.
    let onOpenFolder: (Folder, CGRect) -> Void
    let onMove: (CormorantCore.Tab, UUID) -> Void
    let onClose: (CormorantCore.Tab) -> Void
    let onFolderPrompt: (FolderPrompt) -> Void
    @State private var frames: [UUID: CGRect] = [:]
    @State private var renaming: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    switch item {
                    case .tab(let tab): tile(tab)
                    case .folder(let folder, let tabs): folderTile(folder, tabs: tabs)
                    }
                }
            }
            .padding(.horizontal, 20)
            // Room for the ring and the slash badge.
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .modifier(RenamePinAlert(tabID: $renaming))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned tabs")
        .accessibilityIdentifier("PinnedRow")
    }

    /// The row's pins, as they show: not those in folders.
    private var pins: [CormorantCore.Tab] {
        items.compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
    }

    private func tile(_ tab: CormorantCore.Tab) -> some View {
        let isActive = tab.id == store.state.activeTabID
        return Button {
            onOpen(tab, frames[tab.id] ?? .zero)
        } label: {
            PinTile(tab: tab, favicons: store.favicons, isActive: isActive, accent: accent)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[tab.id] = $0 }
        .contextMenu {
            PinMenu(tab: tab, onRename: { renaming = tab.id }, onMove: { onMove(tab, $0) },
                    onFolderPrompt: onFolderPrompt, onClose: { onClose(tab) })
        }
        .draggable(Self.dragPrefix + tab.id.uuidString) {
            PinTile(tab: tab, favicons: store.favicons, isActive: false, accent: accent)
        }
        // Only a pin's own drag: any other text dropped here is ignored.
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix(Self.dragPrefix),
                  let id = UUID(uuidString: String(item.dropFirst(Self.dragPrefix.count))) else { return false }
            return withAnimation(.snappy(duration: 0.25)) { move(id, onto: tab) }
        }
        .accessibilityLabel(tab.pinName)
        .accessibilityValue(tab.pinAccessibilityValue(isActive: isActive))
        .accessibilityHint("Opens this pinned tab")
        .accessibilityIdentifier("PinnedTab")
        .accessibilityActions {
            if tab.isAwayFromPin {
                Button("Back to Pinned Page") { store.backToPinnedPage(tab.id) }
            }
            if let index = pins.firstIndex(where: { $0.id == tab.id }) {
                if index > 0 { Button("Move Left") { move(tab.id, onto: pins[index - 1]) } }
                if index < pins.count - 1 { Button("Move Right") { move(tab.id, onto: pins[index + 1]) } }
            }
            Button("Rename") { renaming = tab.id }
            Button("New Folder") { onFolderPrompt(.newFolder(tabID: tab.id)) }
            ForEach(store.folders(for: tab.id)) { folder in
                Button("Add to \(folder.name)") { store.addToFolder(tab.id, folder.id) }
            }
            Button("Unpin") { store.unpin(tab.id) }
            Button("Close") { onClose(tab) }
        }
    }

    private func folderTile(_ folder: Folder, tabs: [CormorantCore.Tab]) -> some View {
        let isActive = tabs.contains { $0.id == store.state.activeTabID }
        return Button {
            onOpenFolder(folder, frames[folder.id] ?? .zero)
        } label: {
            FolderTile(folder: folder, isActive: isActive, accent: accent)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[folder.id] = $0 }
        .contextMenu {
            FolderMenu(folder: folder, isPinned: true, onPrompt: onFolderPrompt)
        }
        .accessibilityLabel(folder.name)
        .accessibilityValue("Pinned folder, \(FolderCard.count(tabs.count))")
        .accessibilityHint("Opens this folder")
        .accessibilityIdentifier("PinnedFolder")
        .accessibilityActions {
            Button("Rename") { onFolderPrompt(.rename(folderID: folder.id)) }
            Button("Icon") { onFolderPrompt(.icon(folderID: folder.id)) }
            Button("Unpin Folder") { store.moveFolder(folder.id, toPinned: false) }
            Button("Ungroup") { store.ungroupFolder(folder.id) }
            Button("Close Folder") { store.closeFolder(folder.id) }
        }
    }

    /// A pin dropped on another takes its place, joining the tiles or the pinned list as that one is.
    @discardableResult
    private func move(_ id: UUID, onto target: CormorantCore.Tab) -> Bool {
        store.movePin(id, onto: target.id)
    }

    /// What a dragged pin carries: its tab's ID behind a marker, so a drop knows a pin from other text.
    private static let dragPrefix = "cormorant-pin:"
}

/// The Space's pinned tabs under the search field while composing a new tab, four to a row: tap one
/// to go to it.
struct PinGrid: View {
    @Environment(BrowserStore.self) private var store
    let pins: [CormorantCore.Tab]
    let onOpen: (CormorantCore.Tab) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 14) {
            ForEach(pins) { tab in
                let isActive = tab.id == store.state.activeTabID
                Button {
                    onOpen(tab)
                } label: {
                    PinTile(tab: tab, favicons: store.favicons, isActive: isActive,
                            accent: store.shownSpace?.color.color ?? .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.pinName)
                .accessibilityValue(tab.pinAccessibilityValue(isActive: isActive))
                .accessibilityHint("Goes to this pinned tab")
                .accessibilityIdentifier("PinGridTab")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned tabs")
    }
}
