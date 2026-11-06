import CormorantCore
import SwiftUI

/// Settings › Spaces: Manage Spaces, pushed like the other Settings pages.
struct SpacesSettings: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Section {
            NavigationLink {
                ManageSpacesView(isPage: true)
            } label: {
                LabeledContent("Spaces", value: "\(store.state.switchableSpaces.count)")
            }
        } footer: {
            Text("Separate sets of tabs, each with its own name, look and archive time.")
        }
    }
}
