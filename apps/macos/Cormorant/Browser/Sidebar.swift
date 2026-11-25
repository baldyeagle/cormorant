import AppKit
import CormorantBlocking
import CormorantBrowser
import CormorantCore
import SwiftUI

/// The window's controls, the address, the Space's tiles and pinned list, New Tab and its other tabs
/// newest first, then the Library and the Spaces along the bottom.
struct Sidebar: View {
    let store: BrowserStore
    let commands: WindowCommands
    /// The top row shares the title bar's height, so its buttons line up with the window's.
    let titleBarHeight: CGFloat
    /// On screen and still, so a Space editor can hang off its bottom row.
    let presentsSpaceEditor: Bool
    /// How far a two-finger swipe has carried the Space's address and tabs, the next Space's
    /// following them in (left, negative: the next Space).
    let swipe: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .frame(height: titleBarHeight)
                .padding(.horizontal, 10)
            SpacePages(store: store, commands: commands, swipe: swipe)
                .padding(.top, 6)
            footer
                .padding(.horizontal, 10)
        }
        .padding(.bottom, 10)
    }

    private var controls: some View {
        let session = store.activeSession
        return HStack(spacing: 0) {
            Spacer()
            IconButton(commands.showsSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                commands.showsSidebar.toggle()
            }
            IconButton("Back", systemImage: "chevron.left") { session?.goBack() }
                .disabled(session?.canGoBack != true)
            IconButton("Forward", systemImage: "chevron.right") { session?.goForward() }
                .disabled(session?.canGoForward != true)
            IconButton(session?.isLoading == true ? "Stop" : "Reload",
                       systemImage: session?.isLoading == true ? "xmark" : "arrow.clockwise") { session?.reloadOrStop() }
                .disabled(session == nil)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            LibraryButton(store: store)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Array(store.state.shownSpaces.enumerated()), id: \.element.id) { index, space in
                    SpaceButton(space: space, index: index, store: store, commands: commands,
                                presentsEditor: presentsSpaceEditor)
                }
            }
            Spacer()
            NewSpaceButton(store: store, commands: commands, presentsEditor: presentsSpaceEditor)
        }
        .frame(height: 32)
    }
}

/// The active Space's address and tabs, with its neighbours' beside it for a swipe to bring in.
private struct SpacePages: View {
    let store: BrowserStore
    let commands: WindowCommands
    let swipe: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let spaces = store.state.shownSpaces
            let index = spaces.firstIndex { $0.id == store.state.activeSpaceID }
            ZStack(alignment: .topLeading) {
                // By Space, so a page keeps its own scroll position as it becomes the active one.
                ForEach(neighbours(of: index, in: spaces), id: \.space.id) { step, space in
                    SpacePage(spaceID: space.id, store: store, commands: commands)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: CGFloat(step) * proxy.size.width + swipe)
                }
                if index == nil {
                    SpacePage(spaceID: store.state.activeSpaceID, store: store, commands: commands)
                }
            }
        }
        .clipped()
    }
}

private func neighbours(of index: Int?, in spaces: [Space]) -> [(step: Int, space: Space)] {
    guard let index else { return [] }
    return (-1...1).compactMap { step in spaces.indices.contains(index + step) ? (step, spaces[index + step]) : nil }
}

/// A Space's address, tiles, pinned list and tabs, as switching to it would show them; only the
/// active Space's respond. A line under the tiles starts the pinned list, and one above New Tab ends it.
private struct SpacePage: View {
    let spaceID: UUID
    let store: BrowserStore
    let commands: WindowCommands
    @State private var editor = SidebarEditor()

    var body: some View {
        let isActive = spaceID == store.state.activeSpaceID
        let front = isActive ? store.activeTab : store.state.tabs(inSpace: spaceID).first
        let composing = isActive && store.isComposingNewTab
        let context = SidebarContext(store: store, editor: editor, shownTabID: composing ? nil : front?.id)
        let tiles = store.state.tilePins(inSpace: spaceID)
        let pinned = store.state.pinnedList(inSpace: spaceID)
        let listed = store.state.listedItems(inSpace: spaceID)
        VStack(alignment: .leading, spacing: 0) {
            HostField(store: store, commands: commands, tab: front, isActive: isActive)
            ScrollView {
                VStack(spacing: 2) {
                    if !tiles.isEmpty {
                        TileGrid(tiles: tiles, context: context)
                            .padding(.bottom, pinned.isEmpty ? 0 : 4)
                        if !pinned.isEmpty { SidebarLine() }
                    }
                    ForEach(pinned) { item in
                        SidebarItemRows(item: item, context: context)
                    }
                    if !tiles.isEmpty || !pinned.isEmpty { SidebarLine() }
                    NewTabRow(store: store, isComposing: composing)
                    ForEach(listed) { item in
                        SidebarItemRows(item: item, context: context)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(.top, 12)
                .animation(.snappy(duration: 0.2), value: rowKey(tiles: tiles, pinned: pinned, listed: listed))
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10)
        .environment(\.spaceTint, (store.state.space(spaceID)?.color ?? .teal).color)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
    }

    /// Changes when a row comes, goes or moves, or a folder opens or closes.
    private func rowKey(tiles: [CormorantCore.Tab], pinned: [SidebarItem], listed: [SidebarItem]) -> [UUID] {
        tiles.map(\.id) + (pinned + listed).flatMap { item -> [UUID] in
            guard case .folder(let folder, let tabs) = item else { return [item.id] }
            return [folder.id] + (folder.isOpen ? tabs.map(\.id) : [])
        }
    }
}

/// Divides the tiles, the pinned list and the other tabs.
private struct SidebarLine: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

/// The page's host; a click edits the whole address in the command bar.
private struct HostField: View {
    let store: BrowserStore
    let commands: WindowCommands
    let tab: CormorantCore.Tab?
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Text(host ?? "Search or enter address")
                .foregroundStyle(host == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isActive, let host { PageMenu(store: store, host: host) }
        }
        .font(.system(size: 13.5))
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .frame(height: 36)
        .background(colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.055), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onTapGesture { commands.editAddress(in: store) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(host.map { "Address, \($0)" } ?? "Search or enter address")
        .accessibilityAction { commands.editAddress(in: store) }
    }

    private var host: String? {
        tab?.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}

/// What can be done with the page on screen.
private struct PageMenu: View {
    let store: BrowserStore
    let host: String

    var body: some View {
        Menu {
            // Not Incognito's: per-site choices aren't kept from it. Off for every site, there's no choice.
            if store.activeSession?.isIncognito == false {
                Toggle("Block Trackers on This Site", isOn: Binding(
                    get: { store.blocking.isBlocking(host: host) },
                    set: { _ in store.toggleBlockingForActiveSite() }))
                    .disabled(!store.blocking.preferences.isEnabled)
                Divider()
            }
            Button("Copy Link") {
                guard let url = store.activeTab?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Page Menu")
        .accessibilityLabel("Page Menu")
    }
}

private struct NewTabRow: View {
    let store: BrowserStore
    let isComposing: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .frame(width: 16)
            Text("New Tab")
            Spacer()
            Text("⌘T")
                .font(.system(size: 11.5))
        }
        .foregroundStyle(isComposing ? .primary : .secondary)
        .rowStyle(isActive: isComposing, hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { store.newTab() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A tab: one of the pinned list's (named as its pin, a "/" before the name once it has left its page)
/// or one of the others; in a folder, set in under it.
struct TabRow: View {
    let tab: CormorantCore.Tab
    let context: SidebarContext
    let indented: Bool
    @State private var hovering = false

    var body: some View {
        let store = context.store
        let isActive = tab.id == context.shownTabID
        HStack(spacing: 9) {
            Favicon(url: tab.url, store: store)
            if context.editor.renaming == tab.id {
                NameField(name: title) { store.rename(tab.id, to: $0) } done: { context.editor.renaming = nil }
            } else {
                HStack(spacing: 4) {
                    if tab.isAwayFromPin { Text("/").foregroundStyle(.tertiary) }
                    Text(title)
                }
                .lineLimit(1)
                .fontWeight(isActive ? .medium : .regular)
            }
            Spacer(minLength: 0)
            if hovering, context.editor.renaming != tab.id {
                Button("Close Tab", systemImage: "xmark") { store.close(tab.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .rowStyle(isActive: isActive, hovering: hovering)
        .padding(.leading, indented ? 22 : 0)
        .onHover { hovering = $0 }
        .onTapGesture {
            guard context.editor.renaming != tab.id else { return }
            store.activate(tab.id)
        }
        .accessibilityElement(children: context.editor.renaming == tab.id ? .contain : .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu { TabMenu(tab: tab, context: context) }
    }

    private var title: String { tab.isPinned ? tab.pinName : tab.displayTitle }
}

struct Favicon: View {
    let url: URL?
    let store: BrowserStore
    var size: CGFloat = 16
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let icon = store.favicons.icon(for: url, pixels: Int((size * displayScale).rounded())) {
            Image(decorative: icon, scale: displayScale)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size / 4))
        } else {
            Text(url?.host()?.replacing(/^www\./, with: "").first.map { String($0).uppercased() } ?? "")
                .font(.system(size: size * 0.62, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.gray, in: .rect(cornerRadius: size / 4))
        }
    }
}

/// Downloads and archived Spaces until the Library has its own panel.
private struct LibraryButton: View {
    let store: BrowserStore

    var body: some View {
        Menu {
            Section("Downloads") {
                if store.downloads.listed.isEmpty { Text("No Downloads") }
                ForEach(store.downloads.listed) { item in
                    Button(item.filename) { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                        .disabled(item.status != .finished)
                }
            }
            if !store.state.archivedSpaces.isEmpty {
                Section("Archived Spaces") {
                    ForEach(store.state.archivedSpaces) { space in
                        Button {
                            store.restoreSpace(space.id)
                            store.switchToSpace(space.id)
                        } label: {
                            Image(nsImage: SpaceBadge.menuImage(for: space))
                            Text(space.name)
                            Text(Space.restoreSubtitle(tabCount: store.state.tabCount(inSpace: space.id)))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "books.vertical")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .help("Library")
        .accessibilityLabel("Library")
    }
}

struct IconButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ title: String, systemImage: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help ?? title
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .help(help)
    }
}

extension View {
    func rowStyle(isActive: Bool, hovering: Bool) -> some View {
        modifier(RowStyle(isActive: isActive, hovering: hovering))
    }
}

/// A sidebar row: the tab on screen on white, a hovered one on a shade.
private struct RowStyle: ViewModifier {
    let isActive: Bool
    let hovering: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(background, in: .rect(cornerRadius: 8))
            .shadow(color: isActive && colorScheme == .light ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
            .contentShape(.rect)
    }

    private var background: Color {
        let dark = colorScheme == .dark
        if isActive { return dark ? .white.opacity(0.13) : .white.opacity(0.85) }
        if hovering { return dark ? .white.opacity(0.06) : .black.opacity(0.05) }
        return .clear
    }
}
