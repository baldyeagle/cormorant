import CormorantBrowser
import CormorantSync
import SwiftUI

/// iCloud: the sync switch and how it's going. Not shown where this build can't sync (the simulator,
/// a build with signing off).
struct SyncSettings: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        if store.canSync {
            Section {
                Toggle("Sync Spaces and Tabs", isOn: Binding(
                    get: { store.settings.syncsWithICloud },
                    set: { store.setSync(on: $0) }
                ))
                if let status = store.sync.flatMap({ SyncStatus($0.state) }) {
                    if status.needsAttention {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(status.text).foregroundStyle(.orange)
                            if status.canRetry { Button("Try Again") { store.syncNow() } }
                        }
                    } else {
                        LabeledContent("Status", value: status.text)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(SyncStatus.explanation(device: "iPhone"))
            }
        }
    }
}
