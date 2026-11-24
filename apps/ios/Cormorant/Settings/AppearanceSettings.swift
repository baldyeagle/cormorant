import CormorantBrowser
import SwiftUI

struct AppearanceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Page Under Status Bar", isOn: $settings.pageUnderStatusBar)
            NavigationLink {
                IncognitoIconPicker(settings: settings)
            } label: {
                LabeledContent("Incognito Icon") {
                    HStack(spacing: 6) {
                        IncognitoGlyph(icon: settings.incognitoIcon, isOn: false)
                            .frame(width: 22)
                        Text(settings.incognitoIcon.name)
                    }
                }
            }
            .accessibilityValue(settings.incognitoIcon.name)
            .accessibilityIdentifier("IncognitoIconRow")
        } header: {
            Text("Appearance")
        } footer: {
            Text("The page runs up behind the clock, as in Safari, and the status bar matches it. Off, the status bar sits on a plain strip.")
        }
    }
}

/// The sunglasses Incognito shows, each as it looks when on; tapping one picks it.
private struct IncognitoIconPicker: View {
    @Bindable var settings: AppSettings
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 64

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tile + 8), spacing: 12)], spacing: 16) {
                    ForEach(IncognitoIcon.allCases) { icon in
                        option(icon)
                    }
                }
                .padding(.vertical, 8)
            } footer: {
                Text("Shown on the Incognito button in the search panel, the Incognito Space, and the band at the top of an Incognito tab.")
            }
        }
        .navigationTitle("Incognito Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ icon: IncognitoIcon) -> some View {
        let isSelected = settings.incognitoIcon == icon
        return Button {
            settings.incognitoIcon = icon
        } label: {
            VStack(spacing: 6) {
                IncognitoGlyph(icon: icon)
                    .frame(width: tile * 0.62)
                    .foregroundStyle(.white)
                    .frame(width: tile, height: tile)
                    .background(Color.incognitoBackground, in: .rect(cornerRadius: tile * 0.22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: tile * 0.22 + 4, style: .continuous)
                            .strokeBorder(isSelected ? Color(.brandCyan) : .clear, lineWidth: 2.5)
                            .padding(-4)
                    }
                Text(icon.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(.brandCyan) : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.top, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("IncognitoIcon.\(icon.rawValue)")
    }
}
