import CormorantBlocking
import SwiftUI

/// Global toggle, filter lists, status, manual update, and per-site exceptions.
struct BlockingSettings: View {
    @Environment(BrowserStore.self) private var store

    private var blocking: BlockingService { store.blocking }
    private var disabledHosts: [String] { blocking.preferences.disabledHosts.sorted() }

    var body: some View {
        Section {
            Toggle("Block Ads & Trackers", isOn: binding(\.isEnabled))
            ForEach(FilterListSource.allCases, id: \.self) { source in
                Toggle(source.displayName, isOn: sourceBinding(source))
                    .disabled(!blocking.preferences.isEnabled)
            }
            LabeledContent("Status", value: statusText)
            Button("Update Lists Now") {
                // `refresh` reports failures through `status`, shown in the line above.
                Task { await blocking.refresh(force: true) }
            }
            .disabled(blocking.status == .updating)
        } header: {
            Text("Content Blocking")
        }
        .task {
            // The engine isn't observable; poll its status while Settings is open.
            while !Task.isCancelled {
                blocking.syncStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        Section {
            if disabledHosts.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(disabledHosts, id: \.self) { host in
                Text(host)
            }
            .onDelete { offsets in
                let hosts = offsets.map { disabledHosts[$0] }
                store.updateBlockingPreferences { $0.disabledHosts.subtract(hosts) }
            }
        } header: {
            Text("Blocking Off For")
        } footer: {
            Text("Turn blocking off for a site from the ••• menu in the browser.")
        }
    }

    private var statusText: String {
        switch blocking.status {
        case .idle: "Not loaded yet"
        case .updating: "Updating…"
        case .ready(let lastUpdated, let ruleCount):
            "\(ruleCount.formatted()) rules, updated \(lastUpdated.formatted(.relative(presentation: .named)))"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func binding(_ keyPath: WritableKeyPath<BlockingPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { blocking.preferences[keyPath: keyPath] },
            set: { value in
                store.updateBlockingPreferences { $0[keyPath: keyPath] = value }
                if value { fetchNewlyEnabledLists() }
            }
        )
    }

    private func sourceBinding(_ source: FilterListSource) -> Binding<Bool> {
        Binding(
            get: { blocking.preferences.enabledSources.contains(source) },
            set: { isOn in
                store.updateBlockingPreferences {
                    if isOn { $0.enabledSources.insert(source) } else { $0.enabledSources.remove(source) }
                }
                if isOn { fetchNewlyEnabledLists() }
            }
        )
    }

    /// A list that has never been fetched has nothing to compile until it's downloaded. The engine
    /// reports the new lists through `onListsChanged`, which re-applies them to every tab.
    private func fetchNewlyEnabledLists() {
        Task { await blocking.refresh(force: false) }
    }
}
