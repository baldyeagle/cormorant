import CormorantBrowser
import CormorantSync
import SwiftUI

/// The Settings window (⌘,): iCloud sync's switch and how it's going. Where this build can't sync
/// (signing off), it says so.
struct SettingsWindow: View {
    let store: BrowserStore

    var body: some View {
        Form {
            if store.canSync {
                Toggle("Sync Spaces and tabs with iCloud", isOn: Binding(
                    get: { store.settings.syncsWithICloud },
                    set: { store.setSync(on: $0) }
                ))
                if let sync = store.sync, let status = SyncStatus(sync.state) {
                    if status.needsAttention {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(status.text).foregroundStyle(.orange)
                            if status.canRetry { Button("Try Again") { store.syncNow() } }
                        }
                    } else {
                        LabeledContent("Status") {
                            if sync.state == .idle, let syncedAt = sync.lastSyncedAt {
                                // Said again each minute, so it counts on while the window is open.
                                TimelineView(.periodic(from: .now, by: 60)) { _ in
                                    Text("\(status.text) · synced \(syncedAt.formatted(.relative(presentation: .named)))")
                                }
                            } else {
                                Text(status.text)
                            }
                        }
                    }
                }
                Text(SyncStatus.explanation(device: "Mac"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("iCloud sync isn't available in this build.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
