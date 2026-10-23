import CormorantCore
import SwiftUI

/// The main screen: the active tab's web view under a bottom bar.
struct BrowserView: View {
    @Environment(BrowserStore.self) private var store
    @State private var showSwitcher = false
    @State private var showSettings = false
    @State private var barHeight: CGFloat = 0
    @FocusState private var addressFocused: Bool

    var body: some View {
        ZStack {
            if let session = store.activeSession {
                // Below the status bar; under the bottom bar so its inset scrolls the page clear of it.
                WebViewContainer(webView: session.webView, barHeight: barHeight)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard)
            }
            if store.isLoaded, store.activeTab?.url == nil {
                blankPage
            }
            if let session = store.activeSession, let error = session.loadError {
                LoadErrorView(error: error, onRetry: session.retry)
            }
        }
        .overlay(alignment: .bottom) {
            if let session = store.activeSession, let url = session.blockedDownloadURL {
                DownloadBanner(url: url) { session.blockedDownloadURL = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.activeSession?.blockedDownloadURL)
        .background {
            // Fills the status-bar strip; site-tinted once tabs report a theme color.
            (store.activeSession?.themeColor ?? Color(.systemBackground))
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(
                session: store.activeSession,
                url: store.activeTab?.url,
                addressFocused: $addressFocused,
                showSwitcher: presentSwitcher,
                showSettings: { showSettings = true }
            )
            // Insets track the EXPANDED bar only. Shrinking them when the bar collapses would move
            // the content, and at the end of a page that offset clamp reads as a scroll-up, which
            // re-expands the bar, which shrinks the content again: a visible flicker.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if store.activeSession?.isBarCollapsed != true, height > 0 { barHeight = height }
            }
        }
        .fullScreenCover(isPresented: $showSwitcher, onDismiss: focusIfBlank) {
            TabSwitcherView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Couldn't read saved tabs.", isPresented: loadFailurePresented) {
            Button("Start Fresh") { store.startFresh() }
        } message: {
            if let name = store.loadFailure?.keptCopyName {
                Text("A copy was kept at \(name).")
            } else {
                Text("No copy could be kept. Starting fresh replaces them.")
            }
        }
        .alert("Tabs Are Stored Outside the App Group", isPresented: storageWarningPresented) {
            Button("OK") { store.dismissStorageFallbackWarning() }
        } message: {
            Text("Cormorant's shared container is unavailable, so the share extension can't send links. Reinstall the app to fix this.")
        }
        .onChange(of: store.isLoaded) { focusIfBlank() }
        .onChange(of: store.addressFocusRequest) { addressFocused = true }
        .onChange(of: store.state.activeTabID) { _, _ in
            // A tab opened from outside (share sheet, URL) must not leave the keyboard over the page.
            if store.activeTab?.url != nil { addressFocused = false }
        }
    }

    /// Dismissed only by its action, which clears the failure.
    private var loadFailurePresented: Binding<Bool> {
        Binding(get: { store.loadFailure != nil }, set: { _ in })
    }

    /// Waits for the load-failure alert so the two never compete.
    private var storageWarningPresented: Binding<Bool> {
        Binding(get: { store.showsStorageFallbackWarning && store.isLoaded && store.loadFailure == nil },
                set: { _ in })
    }

    private var blankPage: some View {
        Text("Cormorant")
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .ignoresSafeArea()
            .onTapGesture { addressFocused = false }
    }

    private func presentSwitcher() {
        addressFocused = false
        store.snapshotActiveTab()
        showSwitcher = true
    }

    private func focusIfBlank() {
        if store.activeTab?.url == nil { addressFocused = true }
    }
}
