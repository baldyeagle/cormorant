import SwiftUI

/// Clearing the browsing history the search panel suggests from.
struct HistorySettings: View {
    @Environment(BrowserStore.self) private var store
    @State private var confirming = false

    var body: some View {
        Section {
            Button("Clear History…", role: .destructive) { confirming = true }
                .disabled(store.browsingHistory == nil)
                .confirmationDialog("Clear History", isPresented: $confirming, titleVisibility: .hidden) {
                    Button("Last Hour", role: .destructive) { clear(since: .now.addingTimeInterval(-60 * 60)) }
                    Button("Today", role: .destructive) { clear(since: Calendar.current.startOfDay(for: .now)) }
                    Button("Today and Yesterday", role: .destructive) {
                        let today = Calendar.current.startOfDay(for: .now)
                        // Never nil into `clear`: that clears everything.
                        clear(since: Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today)
                    }
                    Button("All History", role: .destructive) { clear(since: nil) }
                }
        } header: {
            Text("History")
        } footer: {
            Text("Pages you visit and searches you make are suggested as you type. History stays on this device and isn't backed up. Clearing it leaves open tabs and the archive alone.")
        }
    }

    private func clear(since date: Date?) {
        store.clearHistory(since: date)
        UIAccessibility.post(notification: .announcement, argument: "History cleared")
    }
}
