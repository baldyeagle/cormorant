import SwiftUI

/// Whether Cormorant is the default browser, and a way to Default Apps to change it.
struct DefaultBrowserSettings: View {
    let status: DefaultBrowserStatus

    private var isDefault: Bool { status.answer?.isDefault == true }

    private var footer: String {
        if isDefault { return "Links from other apps open in Cormorant." }
        var text = "Opens Settings › Default Apps. Choose Browser App, then Cormorant."
        if status.answer == nil, let retryDate = status.retryDate, retryDate > .now {
            // `isDefault(_:)` is rate-limited; a link from another app is the only other way to know.
            text += " iOS can't check again until \(retryDate.formatted(date: .abbreviated, time: .omitted)); opening a link from another app confirms it sooner."
        }
        return text
    }

    var body: some View {
        Section {
            LabeledContent("Status") {
                switch status.answer?.isDefault {
                case true?:
                    // Not a `Label`: as a Form row's value it took the row's icon layout, and the row
                    // grew hundreds of points tall.
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                        Text("Default Browser")
                    }
                    .foregroundStyle(.green)
                case false?: Text("Not Default")
                case nil: Text("Unknown")
                }
            }
            Button(isDefault ? "Default Apps Settings…" : "Make Default Browser…") {
                status.openDefaultAppsSettings()
            }
        } header: {
            Text("Default Browser")
        } footer: {
            Text(footer)
        }
        .onAppear { status.checkIfStale() }
    }
}
