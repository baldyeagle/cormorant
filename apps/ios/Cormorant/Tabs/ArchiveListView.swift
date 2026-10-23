import CormorantCore
import SwiftUI

/// Archived tabs grouped by day. Tap restores, swipe deletes, Clear empties.
struct ArchiveListView: View {
    @Environment(BrowserStore.self) private var store
    let onRestore: () -> Void

    @State private var query = ""
    @State private var confirmingClear = false

    var body: some View {
        List {
            ForEach(sections, id: \.day) { section in
                Section(Self.title(for: section.day)) {
                    ForEach(section.tabs) { tab in
                        Button {
                            store.restore(tab.id)
                            onRestore()
                        } label: {
                            ArchiveRow(tab: tab)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.deleteArchived(section.tabs[index].id) }
                    }
                }
            }
        }
        .overlay {
            if sections.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Archived Tabs", systemImage: "archivebox",
                                           description: Text("Closed and idle tabs show up here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: "Search archive")
        .navigationTitle("Archive")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) { confirmingClear = true }
                    .disabled(store.state.archived.isEmpty)
            }
        }
        .confirmationDialog("Clear the archive?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Archive", role: .destructive) { store.clearArchive() }
        } message: {
            Text("All archived tabs will be removed. This can't be undone.")
        }
    }

    private var sections: [(day: Date, tabs: [ArchivedTab])] {
        let all = store.state.archivedByDay()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.compactMap { section in
            let matches = section.tabs.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || ($0.url.host() ?? "").localizedCaseInsensitiveContains(needle)
            }
            return matches.isEmpty ? nil : (section.day, matches)
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct ArchiveRow: View {
    let tab: ArchivedTab

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle).lineLimit(1)
                Text(tab.url.displayHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(tab.archivedAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
