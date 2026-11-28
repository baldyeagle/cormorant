import CormorantBrowser
import CormorantCore
import OSLog
import SwiftUI

/// Full-screen card stack of the active Space's tabs and folders, under a row of its pins (`PinnedRow`).
/// The most recently viewed card sits on top. A folder's card shows its tabs' cards on their own; a
/// pinned folder's tile opens its panel over the switcher.
struct TabSwitcherView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// How much of each card the next one covers.
    private static let overlap: CGFloat = 0.26
    /// Per card-step away from the center: the tilt, the drop (times the steps squared, so the row
    /// bends like a hand of cards) and the shrink. Turning about the card's own center keeps the
    /// overlap; a pivot below the screen would swing the outer cards apart.
    nonisolated private static let tiltPerStep: Double = 4
    nonisolated private static let dropPerStep: CGFloat = 10
    nonisolated private static let shrinkPerStep: CGFloat = 0.03
    private static let closeAnimation = Animation.snappy(duration: 0.25)

    /// The card growing into the page, once one is tapped. Never cleared while the switcher is up:
    /// the chosen tab is the browser's from then on (see `onFinished` below).
    @State private var opening: Opening?
    @State private var presence = Presence()
    /// The folder whose cards show on their own, from its card.
    @State private var openFolderID: UUID?
    /// The pinned folder whose panel is up, from its tile.
    @State private var panel: PanelRequest?
    @State private var folderPrompt: FolderPrompt?
    /// Cards being closed, which fly up as they go; a card leaving otherwise (into a folder) fades.
    @State private var closing: Set<UUID> = []

    var body: some View {
        let pinRow = store.pinRow
        NavigationStack {
          VStack(spacing: 0) {
            if !pinRow.isEmpty {
                PinnedRow(items: pinRow, accent: accent,
                          onOpen: { tab, frame in open(tab, from: frame, tilt: 0) },
                          onOpenFolder: { folder, frame in openPanel(folder, from: frame) },
                          onMove: { tab, spaceID in move(tab, to: spaceID) },
                          onClose: { close($0) },
                          onFolderPrompt: { folderPrompt = $0 })
                    // Another Space's pins replace these whole, as its cards do.
                    .id(store.state.activeSpaceID)
                    .transition(.opacity)
            }
            if let shown = shownFolder {
                FolderBackPill(folder: shown.folder, accent: accent, onBack: showAllTabs)
                    .padding(.top, pinRow.isEmpty ? 8 : 0)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            GeometryReader { geometry in
                let cardSize = Self.cardSize(in: geometry.size)
                let step = cardSize.width * (1 - Self.overlap)
                let viewportMidX = geometry.size.width / 2
                let fans = !reduceMotion
                let stack = self.stack
                ScrollView(.horizontal) {
                    // Lazy: only the cards in view are built. With every card built, closing one rebuilt
                    // them all, a stall that grew with the Space's tabs (130 ms at 74 on an iPhone 16 Pro).
                    LazyHStack(spacing: -cardSize.width * Self.overlap) {
                        ForEach(stack) { item in
                            let labelWidth = item.id == stack.last?.id ? cardSize.width : max(0, step - 10)
                            Group {
                                switch item {
                                case .tab(let tab):
                                    TabCard(
                                        tab: tab,
                                        snapshot: store.snapshots[tab.id]?.content,
                                        favicons: store.favicons,
                                        isActive: tab.id == store.state.activeTabID,
                                        accent: accent,
                                        size: cardSize,
                                        labelWidth: labelWidth,
                                        onOpen: { frame in
                                            // The fan's scale and tilt for where the card sits (see visualEffect below).
                                            let offset = fans ? (frame.midX - geometry.frame(in: .global).midX) / step : 0
                                            let scale = 1 - Self.shrinkPerStep * min(abs(offset), 3)
                                            let start = frame.insetBy(dx: frame.width * (1 - scale) / 2,
                                                                      dy: frame.height * (1 - scale) / 2)
                                            open(tab, from: start, tilt: Self.tiltPerStep * offset)
                                        },
                                        onClose: { close(tab) }
                                    )
                                    // Before the fan's tilt, so the menu's preview is the card as it is.
                                    .modifier(CardMenu(tab: tab, onMove: { move(tab, to: $0) },
                                                       onFolderPrompt: { folderPrompt = $0 }, onClose: { close(tab) }))
                                case .folder(let folder, let tabs):
                                    FolderCard(
                                        folder: folder,
                                        tabs: tabs,
                                        snapshot: tabs.first.flatMap { store.snapshots[$0.id]?.content },
                                        favicons: store.favicons,
                                        isActive: tabs.contains { $0.id == store.state.activeTabID },
                                        accent: accent,
                                        size: cardSize,
                                        labelWidth: labelWidth,
                                        onOpen: { showFolder(folder.id) }
                                    )
                                    .contextMenu {
                                        FolderMenu(folder: folder, isPinned: false, onPrompt: { folderPrompt = $0 })
                                    }
                                    .accessibilityActions {
                                        Button("Rename") { folderPrompt = .rename(folderID: folder.id) }
                                        Button("Icon") { folderPrompt = .icon(folderID: folder.id) }
                                        Button("Pin Folder") { store.moveFolder(folder.id, toPinned: true) }
                                        Button("Ungroup") { store.ungroupFolder(folder.id) }
                                        Button("Close Folder") { store.closeFolder(folder.id) }
                                    }
                                }
                            }
                            .visualEffect { content, proxy in
                                // Steps from the center, fractional while scrolling.
                                let offset = fans ? (proxy.frame(in: .scrollView).midX - viewportMidX) / step : 0
                                let steps = min(abs(offset), 3)
                                return content
                                    .scaleEffect(1 - Self.shrinkPerStep * steps)
                                    .rotationEffect(.degrees(Self.tiltPerStep * offset))
                                    .offset(y: Self.dropPerStep * steps * steps)
                            }
                            .transition(.asymmetric(
                                insertion: .identity,
                                removal: reduceMotion || !closing.contains(item.id)
                                    ? .opacity : .offset(y: -cardSize.height * 0.6).combined(with: .opacity)
                            ))
                        }
                    }
                    .padding(.horizontal, (geometry.size.width - cardSize.width) / 2)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
                // Another Space's cards, or a folder's, replace these whole, scrolled to the newest,
                // rather than leaving one by one as closed cards do.
                .id([store.state.activeSpaceID, shownFolder?.folder.id])
                .transition(.opacity)
            }
          }
            // As switching Spaces here does, for a toast's Undo or Back, which switch from the store.
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25), value: store.state.activeSpaceID)
            // Above the bottom bar: a card moved to another Space says so, with Undo and Back.
            .overlay(alignment: .bottom) {
                ToastHost(isSuppressed: opening != nil)
                    .padding(.bottom, 8)
            }
            .overlay {
                if store.tabs.isEmpty {
                    ContentUnavailableView {
                        Label("No Open Tabs", systemImage: "square.on.square")
                    } description: {
                        Text("Closed pages are in the archive, top left.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            // The Space's color from the top, fading out by 340pt, once there are Spaces to switch.
            .background(alignment: .top) {
                if let space = store.shownSpace {
                    LinearGradient(colors: [space.color.switcherWash, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 340)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // Incognito's cards sit on black, in light mode too, as its tabs' bar does.
            .environment(\.colorScheme, isIncognito ? .dark : colorScheme)
            .toolbarColorScheme(isIncognito ? .dark : nil, for: .navigationBar)
            .modifier(FolderPrompts(prompt: $folderPrompt))
        }
        // A toast's Move… while the switcher is up: the browser can't present over it.
        .sheet(item: Binding(get: { store.moveRequest }, set: { store.moveRequest = $0 })) { request in
            MoveToSpaceSheet(tabID: request.tabID, onMoved: { store.moveRequest = nil })
        }
        .onAppear { presence.isPresented = true }
        .onDisappear { presence.isPresented = false }
        .background(PresenceAnchor(presence: presence))
        .overlay { folderPanel }
        .onChange(of: store.state.activeSpaceID) {
            openFolderID = nil
            panel = nil
        }
        // A folder that goes (closed, ungrouped, emptied, pinned or unpinned) takes its view with it.
        .onChange(of: shownFolder?.folder.id) { _, id in if id == nil { openFolderID = nil } }
        .onChange(of: panelFolder?.folder.id) { _, id in if id == nil { panel = nil } }
        // Once a card is chosen nothing in the switcher takes a touch or a VoiceOver action, the
        // toolbar included.
        .allowsHitTesting(opening == nil)
        .disabled(opening != nil)
        .overlay {
            if let opening {
                GeometryReader { geometry in
                    CardExpansion(
                        // The card's header covers the preview's top corners; only the bottom ones are round.
                        card: CardExpansion.Card(frame: opening.from, tilt: opening.tilt, bottomRadius: 22),
                        snapshot: opening.snapshot,
                        host: opening.host,
                        // Where the browser draws the page, as the card shows it: below the status bar
                        // and down to the bottom edge, under the bar (see BrowserView's WebViewContainer).
                        // Behind the status bar, the backdrop and the snapshot's band fill in.
                        page: CGRect(x: geometry.safeAreaInsets.leading, y: geometry.safeAreaInsets.top,
                                     width: geometry.size.width,
                                     height: geometry.size.height + geometry.safeAreaInsets.bottom),
                        // The color behind the status bar for the tab, so the page lands with no seam.
                        backdrop: { store.stripColor(in: colorScheme) },
                        onFinished: {
                            // The snapshot now covers the page's place in the browser: swap without a slide.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            if !Self.skipsFirstDismiss { withTransaction(transaction) { dismiss() } }
                            // Should the dismiss not take (one already under way, say), close it again:
                            // never by bringing the switcher back to life, which, still up but not drawn
                            // over the page, would take taps meant for the page and switch tabs. SwiftUI
                            // first; then, its state already saying closed, UIKit.
                            let presence = presence
                            let dismiss = dismiss
                            Task {
                                for attempt in 1...3 {
                                    try? await Task.sleep(for: .seconds(1))
                                    guard presence.isPresented else { return }
                                    Logger.app.error("Tab switcher still up \(attempt) s after opening a tab; closing it again")
                                    if attempt == 1 {
                                        withTransaction(transaction) { dismiss() }
                                    } else {
                                        presence.dismissFromUIKit()
                                    }
                                }
                            }
                        }
                    )
                    .ignoresSafeArea()
                }
            }
        }
    }

    /// The Space's tabs and folders but its pinned ones (or the open folder's tabs), oldest first so the
    /// newest is last: frontmost and scrolled into view. Held in place while a card opens, since
    /// activating it makes it the newest.
    private var stack: [SidebarItem] {
        let items: [SidebarItem] = shownFolder.map { $0.tabs.reversed().map(SidebarItem.tab) }
            ?? store.unpinnedItems.reversed()
        guard let order = opening?.order else { return items }
        return items.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private var accent: Color { store.shownSpace?.color.color ?? .accentColor }

    /// The folder whose cards show on their own, while it's among the Space's other tabs.
    private var shownFolder: (folder: Folder, tabs: [CormorantCore.Tab])? {
        guard let openFolderID else { return nil }
        for case .folder(let folder, let tabs) in store.unpinnedItems where folder.id == openFolderID {
            return (folder, tabs)
        }
        return nil
    }

    /// The pinned folder whose panel is up, while it's pinned.
    private var panelFolder: (folder: Folder, tabs: [CormorantCore.Tab])? {
        guard let panel else { return nil }
        for case .folder(let folder, let tabs) in store.pinRow where folder.id == panel.folderID {
            return (folder, tabs)
        }
        return nil
    }

    private var folderAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3)
    }

    private func showFolder(_ folderID: UUID) {
        guard opening == nil else { return }
        withAnimation(folderAnimation) { openFolderID = folderID }
    }

    private func showAllTabs() {
        withAnimation(folderAnimation) { openFolderID = nil }
    }

    private func openPanel(_ folder: Folder, from frame: CGRect) {
        guard opening == nil else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15)) {
            panel = PanelRequest(folderID: folder.id, tile: frame)
        }
    }

    private func closePanel() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.28)) { panel = nil }
    }

    /// A pinned folder's panel over the blurred switcher, growing from its tile and going back into it.
    private var folderPanel: some View {
        GeometryReader { geometry in
            let bounds = geometry.frame(in: .global)
            ZStack {
                if let request = panel, let shown = panelFolder {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .onTapGesture(perform: closePanel)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    let zoom = FolderPanelZoom(
                        offset: request.tile == .zero ? .zero
                            : CGSize(width: request.tile.midX - bounds.midX, height: request.tile.midY - bounds.midY),
                        scale: reduceMotion ? 1 : 0.2, opacity: 0)
                    FolderPanel(folder: shown.folder, tabs: shown.tabs, accent: accent,
                                onOpen: { tab, frame in open(tab, from: frame, tilt: 0) },
                                onClose: { close($0) },
                                onPrompt: { folderPrompt = $0 },
                                onDismiss: closePanel)
                        .frame(width: min(geometry.size.width - 48, 380))
                        .frame(maxHeight: geometry.size.height * 0.72)
                        .transition(.modifier(active: zoom, identity: FolderPanelZoom(offset: .zero, scale: 1, opacity: 1)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func close(_ tab: CormorantCore.Tab) {
        closing.insert(tab.id)
        // A turn later, so the card leaves with the transition `closing` gives it.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.closeAnimation) {
                store.close(tab.id)
            }
            closing.remove(tab.id)
        }
    }

    /// The switcher goes with the card to its new Space, where it's on top; the toast says where it went.
    private func move(_ tab: CormorantCore.Tab, to spaceID: UUID) {
        guard opening == nil else { return }
        closing.insert(tab.id)
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.closeAnimation) {
                store.moveTab(tab.id, toSpace: spaceID)
            }
            closing.remove(tab.id)
        }
    }

    /// Switches to the tab under the switcher, then grows its card into the page.
    private func open(_ tab: CormorantCore.Tab, from frame: CGRect, tilt: Double) {
        guard opening == nil else { return }
        let order = Dictionary(uniqueKeysWithValues: stack.enumerated().map { ($1.id, $0) })
        // A band from when the page ran under the status bar isn't what's behind it now.
        let snapshot = store.snapshots[tab.id].map { store.pageRunsUnderStatusBar ? $0 : $0.contentOnly }
        opening = Opening(snapshot: snapshot, host: tab.url?.displayHost ?? "",
                          from: frame, tilt: tilt, order: order)
        store.activate(tab.id)
    }

    /// Switches the cards to the Space's tabs. The switcher stays up: Done (or a card) goes to them.
    /// Not once a card is opening, nor once New Tab or Search Tabs has the switcher closing (switching
    /// would drop what they asked for).
    private func switchToSpace(_ spaceID: UUID) {
        guard opening == nil, !store.isComposingNewTab, !store.isSearchingTabs else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) {
            store.switchToSpace(spaceID)
        }
    }

    private var isIncognito: Bool { store.state.activeSpaceID == Space.incognitoID }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let space = store.shownSpace {
            // The Space's name in place of the tab count; it opens the same list as the tabs button.
            ToolbarItem(placement: .principal) {
                Menu {
                    SpaceMenuList(onSwitch: switchToSpace)
                    Section {
                        Button("Manage Spaces", systemImage: "square.stack") { store.showManageSpaces() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        SpaceBadge(space: space)
                        Text(space.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Space, \(space.name)")
                // What the title said before Spaces.
                .accessibilityValue(title)
                .accessibilityHint("Switches Spaces")
                .accessibilityIdentifier("SpaceTitleMenu")
            }
        }
        // Nothing in Incognito is ever archived.
        if !isIncognito {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ArchiveListView(onRestore: { dismiss() })
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
        }
    }

    /// Each round control's side, and the bar's height: the strip's tallest slot (44pt, at the largest
    /// text sizes) inside its capsule.
    fileprivate static let control: CGFloat = 48
    /// At least this between the strip and New Tab.
    private static let gap: CGFloat = 8
    /// The strip's capsule around its slots.
    private static let stripInset: CGFloat = 2

    /// Spaces on the left, New Tab in the middle of the screen however many Spaces are beside it, and
    /// Search Tabs on the right. Not the system's bottom toolbar: that centers an item between its
    /// neighbors, so New Tab would move with the strip.
    private var bottomBar: some View {
        GeometryReader { geometry in
            // The strip's slots: up to New Tab, less the gap and the strip's capsule.
            let stripWidth = geometry.size.width / 2 - Self.control / 2 - Self.gap - 2 * Self.stripInset
            // Spacing 0: each control's glass stays its own, never blending into the next.
            GlassEffectContainer(spacing: 0) {
                ZStack {
                    HStack(spacing: 0) {
                        if store.hasSpacesToSwitch {
                            SpaceStrip(onSwitch: switchToSpace, slots: SpaceStrip.slots(in: stripWidth))
                                .padding(.horizontal, Self.stripInset)
                                .frame(height: Self.control)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        } else {
                            // With only Home, the one sign Spaces exist: Manage Spaces, where New Space lives.
                            // The browser closes the switcher on the way (`presentManageSpaces`).
                            BarButton("Spaces", systemImage: "square.stack") { store.showManageSpaces() }
                                .accessibilityHint("Creates and manages Spaces")
                                .accessibilityIdentifier("ManageSpacesButton")
                        }
                        Spacer(minLength: 0)
                        // Searches in the search panel once the switcher is gone, like New Tab.
                        BarButton("Search Tabs", systemImage: "magnifyingglass") {
                            store.searchTabs()
                            dismiss()
                        }
                        .disabled(store.tabs.isEmpty)
                        .accessibilityIdentifier("SwitcherSearchTabs")
                    }
                    // Composes in the search panel once the switcher is gone; no tab exists until Go.
                    BarButton("New Tab", systemImage: "plus") {
                        store.newTab()
                        dismiss()
                    }
                    .accessibilityIdentifier("SwitcherNewTab")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: Self.control)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var title: String {
        switch store.tabs.count {
        case 0: "No Tabs"
        case 1: "1 Tab"
        case let count: "\(count) Tabs"
        }
    }

    /// The card below its label. Narrow enough that the cards either side of the center one show.
    private static func cardSize(in size: CGSize) -> CGSize {
        let width = size.width * 0.7
        return CGSize(width: width, height: min(width * 1.9, size.height * 0.78))
    }
}

/// A round glass button in the switcher's bottom bar, its symbol the size the system's toolbar draws.
private struct BarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: TabSwitcherView.control, height: TabSwitcherView.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(isEnabled), in: .circle)
        .accessibilityLabel(title)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}

/// A card's long-press menu: Pin Tab (not in Incognito), Add to Folder (not in Incognito), Remove from
/// Folder (in one), Move to Space (with more than one Space), and Close Tab. VoiceOver gets Pin, the
/// folder choices and each move as actions of their own.
private struct CardMenu: ViewModifier {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: CormorantCore.Tab
    let onMove: (UUID) -> Void
    let onFolderPrompt: (FolderPrompt) -> Void
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if store.canPin(tab.id) {
                    Button("Pin Tab", systemImage: "pin") { store.pin(tab.id) }
                }
                if !tab.isIncognito {
                    AddToFolderMenu(tabID: tab.id, onPrompt: onFolderPrompt)
                }
                if tab.folderID != nil {
                    Button("Remove from Folder", systemImage: "folder.badge.minus", action: removeFromFolder)
                }
                // Not for an Incognito tab, or with only Home and Incognito.
                if !store.moveDestinations(for: tab.id).isEmpty {
                    MoveToSpaceMenu(tabID: tab.id, onMove: onMove)
                }
                Button("Close Tab", systemImage: "xmark", role: .destructive, action: onClose)
            }
            .accessibilityActions {
                if store.canPin(tab.id) {
                    Button("Pin Tab") { store.pin(tab.id) }
                }
                if !tab.isIncognito {
                    Button("New Folder") { onFolderPrompt(.newFolder(tabID: tab.id)) }
                    ForEach(store.folders(for: tab.id)) { folder in
                        Button("Add to \(folder.name)") { store.addToFolder(tab.id, folder.id) }
                    }
                }
                if tab.folderID != nil {
                    Button("Remove from Folder", action: removeFromFolder)
                }
                ForEach(store.moveDestinations(for: tab.id).filter { !$0.isCurrent }) { destination in
                    Button("Move to \(destination.space.name)") { onMove(destination.space.id) }
                }
            }
    }

    private func removeFromFolder() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) {
            store.removeFromFolder(tab.id)
        }
    }
}

extension TabSwitcherView {
    /// `-uiTestingSkipsFirstSwitcherDismiss` (UI tests): opening a tab doesn't dismiss the switcher,
    /// as when a dismiss doesn't take, so the fallback does.
    fileprivate static var skipsFirstDismiss: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiTestingSkipsFirstSwitcherDismiss")
        #else
        false
        #endif
    }
}

/// The switcher's presentation, for work that outlives a dismiss call: whether it's still up, and a
/// way to close it from UIKit when SwiftUI's own dismiss hasn't.
@MainActor
private final class Presence {
    var isPresented = false
    weak var anchor: UIView?

    func dismissFromUIKit() {
        var responder = anchor?.next
        while let current = responder {
            if let controller = current as? UIViewController, let presenting = controller.presentingViewController {
                presenting.dismiss(animated: false)
                return
            }
            responder = current.next
        }
    }
}

/// Puts a view in the switcher's UIKit hierarchy for `Presence` to find its presentation from.
private struct PresenceAnchor: UIViewRepresentable {
    let presence: Presence

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        presence.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

private struct PanelRequest {
    let folderID: UUID
    /// The folder's tile on screen.
    let tile: CGRect
}

private struct Opening {
    let snapshot: PageSnapshot?
    let host: String
    /// The card's preview on screen, and its tilt in the fan.
    let from: CGRect
    let tilt: Double
    /// The stack's order when the card was tapped.
    let order: [UUID: Int]
}
