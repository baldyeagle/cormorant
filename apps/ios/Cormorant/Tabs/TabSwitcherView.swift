import CormorantCore
import OSLog
import SwiftUI

/// Full-screen card stack of the active Space's tabs. The most recently viewed card sits on top.
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

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let cardSize = Self.cardSize(in: geometry.size)
                let step = cardSize.width * (1 - Self.overlap)
                let viewportMidX = geometry.size.width / 2
                let fans = !reduceMotion
                let stack = self.stack
                ScrollView(.horizontal) {
                    HStack(spacing: -cardSize.width * Self.overlap) {
                        ForEach(stack) { tab in
                            TabCard(
                                tab: tab,
                                snapshot: store.snapshots[tab.id]?.content,
                                favicons: store.favicons,
                                isActive: tab.id == store.state.activeTabID,
                                accent: store.shownSpace?.color.color ?? .accentColor,
                                size: cardSize,
                                labelWidth: tab.id == stack.last?.id ? cardSize.width : max(0, step - 10),
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
                            .modifier(CardMenu(tab: tab, isEnabled: store.hasSpacesToSwitch,
                                               onMove: { move(tab, to: $0) }, onClose: { close(tab) }))
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
                                removal: reduceMotion ? .opacity : .offset(y: -cardSize.height * 0.6).combined(with: .opacity)
                            ))
                        }
                    }
                    .padding(.horizontal, (geometry.size.width - cardSize.width) / 2)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
                // Another Space's cards replace these whole, scrolled to its newest, rather than
                // leaving one by one as closed cards do.
                .id(store.state.activeSpaceID)
                .transition(.opacity)
            }
            // Above the bottom toolbar: a card moved to another Space says where it went.
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
        }
        // A toast's Move… while the switcher is up: the browser can't present over it.
        .sheet(item: Binding(get: { store.moveRequest }, set: { store.moveRequest = $0 })) { request in
            MoveToSpaceSheet(tabID: request.tabID, onMoved: { store.moveRequest = nil })
        }
        .onAppear { presence.isPresented = true }
        .onDisappear { presence.isPresented = false }
        .background(PresenceAnchor(presence: presence))
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

    /// Oldest first so the newest is last: frontmost and scrolled into view. Held in place while a card
    /// opens, since activating it makes it the newest.
    private var stack: [CormorantCore.Tab] {
        let tabs = Array(store.tabs.reversed())
        guard let order = opening?.order else { return tabs }
        return tabs.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private func close(_ tab: CormorantCore.Tab) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.closeAnimation) {
            store.close(tab.id)
        }
    }

    /// The card leaves as a closed one does; the toast says where it went.
    private func move(_ tab: CormorantCore.Tab, to spaceID: UUID) {
        guard opening == nil else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.closeAnimation) {
            store.moveTab(tab.id, toSpace: spaceID)
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
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                ArchiveListView(onRestore: { dismiss() })
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
        }
        if store.hasSpacesToSwitch {
            ToolbarItem(placement: .bottomBar) {
                SpaceStrip(onSwitch: switchToSpace)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        } else {
            // With only Home, the one sign Spaces exist: Manage Spaces, where New Space lives.
            ToolbarItem(placement: .bottomBar) {
                // The browser closes the switcher on the way (`presentManageSpaces`).
                Button("Spaces", systemImage: "square.stack") { store.showManageSpaces() }
                .accessibilityHint("Creates and manages Spaces")
                .accessibilityIdentifier("ManageSpacesButton")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            // Searches in the search panel once the switcher is gone, like New Tab.
            Button("Search Tabs", systemImage: "magnifyingglass") {
                store.searchTabs()
                dismiss()
            }
            .disabled(store.tabs.isEmpty)
        }
        ToolbarItem(placement: .bottomBar) {
            // Composes in the search panel once the switcher is gone; no tab exists until Go.
            Button("New Tab", systemImage: "plus") {
                store.newTab()
                dismiss()
            }
        }
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

/// A card's long-press menu, with more than one Space: Move to Space, and Close Tab. With only Home
/// a card has no menu, as before Spaces. VoiceOver gets each move as an action of its own.
private struct CardMenu: ViewModifier {
    @Environment(BrowserStore.self) private var store
    let tab: CormorantCore.Tab
    let isEnabled: Bool
    let onMove: (UUID) -> Void
    let onClose: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contextMenu {
                    MoveToSpaceMenu(tabID: tab.id, onMove: onMove)
                    Button("Close Tab", systemImage: "xmark", role: .destructive, action: onClose)
                }
                .accessibilityActions {
                    ForEach(store.moveDestinations(for: tab.id).filter { !$0.isCurrent }) { destination in
                        Button("Move to \(destination.space.name)") { onMove(destination.space.id) }
                    }
                }
        } else {
            content
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

private struct Opening {
    let snapshot: PageSnapshot?
    let host: String
    /// The card's preview on screen, and its tilt in the fan.
    let from: CGRect
    let tilt: Double
    /// The stack's order when the card was tapped.
    let order: [UUID: Int]
}
