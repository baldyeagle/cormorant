import CormorantCore
import SwiftUI

/// Built-in engines plus one user-defined engine.
struct SearchEngineSettings: View {
    @Bindable var settings: AppSettings

    private var engines: [SearchEngine] {
        SearchEngine.builtIn + (settings.customSearchEngine.map { [$0] } ?? [])
    }

    var body: some View {
        Section("Search Engine") {
            Picker("Search Engine", selection: $settings.searchEngine) {
                ForEach(engines) { engine in
                    Text(engine.name).tag(engine)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            NavigationLink("Custom…") {
                CustomSearchEngineForm(settings: settings)
            }
        }
    }
}

private struct CustomSearchEngineForm: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTemplate: String { template.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Needs `{query}` and must form an http(s) URL once a query is substituted.
    private var isValid: Bool {
        guard !trimmedName.isEmpty, trimmedTemplate.contains("{query}"),
              let url = URL(string: trimmedTemplate.replacing("{query}", with: "test")),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { return false }
        return true
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("https://example.com/search?q={query}", text: $template)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Put {query} where the search terms go.")
            }
        }
        .navigationTitle("Custom Engine")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!isValid)
            }
        }
        .onAppear {
            guard let custom = settings.customSearchEngine else { return }
            name = custom.name
            template = custom.queryTemplate
        }
    }

    private func save() {
        let engine = SearchEngine(id: AppSettings.customEngineID, name: trimmedName, queryTemplate: trimmedTemplate)
        settings.customSearchEngine = engine
        settings.searchEngine = engine
        dismiss()
    }
}
