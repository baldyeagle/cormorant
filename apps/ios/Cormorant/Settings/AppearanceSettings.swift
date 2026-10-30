import SwiftUI

struct AppearanceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Tint with Website Colors", isOn: $settings.tintsChrome)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The strip behind the status bar takes on the color at the top of the page.")
        }
    }
}
