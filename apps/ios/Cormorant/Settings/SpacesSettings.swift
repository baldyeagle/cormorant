import CormorantCore
import SwiftUI

/// The way into Manage Spaces, which the browser presents once Settings and the caret sheet have gone.
struct SpacesSettings: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Section {
            Button { store.showManageSpaces() } label: {
                HStack {
                    Text("Spaces")
                    Spacer()
                    Text("\(store.state.switchableSpaces.count)")
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Spaces")
            .accessibilityValue("\(store.state.switchableSpaces.count)")
            .accessibilityHint("Closes Settings and opens Manage Spaces")
        } footer: {
            Text("Separate sets of tabs, each with its own name, look and archive time.")
        }
    }
}
