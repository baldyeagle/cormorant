import SwiftUI

struct SettingsView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DefaultBrowserSettings(status: store.defaultBrowser)
                SpacesSettings()
                TabsSettings()
                SearchEngineSettings(settings: store.settings)
                HistorySettings()
                AppearanceSettings(settings: store.settings)
                BlockingSettings()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
