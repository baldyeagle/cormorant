import SwiftUI

struct AppearanceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Page Under Status Bar", isOn: $settings.pageUnderStatusBar)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The page runs up behind the clock, as in Safari, and the status bar matches it. Off, the status bar sits on a plain strip.")
        }
    }
}
