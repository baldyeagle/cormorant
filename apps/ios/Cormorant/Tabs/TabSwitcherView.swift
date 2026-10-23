import CormorantCore
import SwiftUI

/// Full-screen card stack of the active Space's tabs. The most recently viewed card sits on top.
struct TabSwitcherView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let cardSize = Self.cardSize(in: geometry.size)
                ScrollView(.horizontal) {
                    // Oldest first so the newest is last: frontmost and scrolled into view.
                    HStack(spacing: -cardSize.width * 0.45) {
                        ForEach(store.tabs.reversed()) { tab in
                            TabCard(
                                tab: tab,
                                snapshot: store.snapshots[tab.id],
                                isActive: tab.id == store.state.activeTabID,
                                size: cardSize,
                                onClose: { store.close(tab.id) }
                            )
                            .onTapGesture {
                                store.activate(tab.id)
                                dismiss()
                            }
                        }
                    }
                    .padding(.horizontal, (geometry.size.width - cardSize.width) / 2)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
                .animation(.snappy, value: store.tabs.map(\.id))
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
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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

    private static func cardSize(in size: CGSize) -> CGSize {
        let height = size.height * 0.78
        return CGSize(width: min(size.width * 0.72, height * 0.62), height: height)
    }
}
