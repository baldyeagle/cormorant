import SwiftUI

struct SettingsView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(DefaultBrowserStatus.self) private var defaultBrowser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DefaultBrowserSettings(status: defaultBrowser)
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
