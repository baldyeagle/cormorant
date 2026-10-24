import SwiftUI

struct AppearanceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Tint with Website Colors", isOn: $settings.tintsChrome)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The toolbar and status bar take on the color a website asks for.")
        }
    }
}
