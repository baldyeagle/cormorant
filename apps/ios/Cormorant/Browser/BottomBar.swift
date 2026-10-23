import SwiftUI

/// Back/forward, address field, tabs, and the overflow menu. Shrinks to a strip while scrolling down.
struct BottomBar: View {
    @Environment(BrowserStore.self) private var store
    let session: TabSession?
    let url: URL?
    var addressFocused: FocusState<Bool>.Binding
    let showSwitcher: () -> Void
    let showSettings: () -> Void

    private var isCollapsed: Bool { (session?.isBarCollapsed ?? false) && !addressFocused.wrappedValue }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: session?.progress ?? 0)
                .progressViewStyle(.linear)
                .opacity(session?.isLoading == true ? 1 : 0)

            if isCollapsed {
                collapsedStrip
            } else {
                fullBar
            }
        }
        // Collapsed, the strip sinks into the home-indicator zone like Safari's, so the whole
        // thing is a thin sliver rather than a label stacked above the safe area.
        .padding(.bottom, isCollapsed ? -18 : 0)
        .background(.bar)
    }

    private var collapsedStrip: some View {
        Button {
            session?.isBarCollapsed = false
        } label: {
            Text(url?.displayHost ?? "")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show toolbar")
    }

    private var fullBar: some View {
        HStack(spacing: 8) {
            if !addressFocused.wrappedValue {
                Button("Back", systemImage: "chevron.backward") { session?.goBack() }
                    .disabled(session?.canGoBack != true)
                Button("Forward", systemImage: "chevron.forward") { session?.goForward() }
                    .disabled(session?.canGoForward != true)
            }

            AddressField(
                url: url,
                isLoading: session?.isLoading == true,
                isFocused: addressFocused,
                onSubmit: store.submit,
                onReloadOrStop: { session?.reloadOrStop() }
            )

            if addressFocused.wrappedValue {
                Button("Cancel") { addressFocused.wrappedValue = false }
                    .labelStyle(.titleOnly)
            } else {
                tabsButton
                OverflowMenu(url: url, showSettings: showSettings)
            }
        }
        .labelStyle(.iconOnly)
        .imageScale(.large)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Tap opens the switcher; long-press offers "New Tab".
    private var tabsButton: some View {
        Menu {
            Button("New Tab", systemImage: "plus") { store.newTab() }
        } label: {
            Text(store.tabs.count, format: .number)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 22, minHeight: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.6))
                .padding(4)
        } primaryAction: {
            showSwitcher()
        }
        .accessibilityLabel("Tabs, \(store.tabs.count) open")
    }
}
