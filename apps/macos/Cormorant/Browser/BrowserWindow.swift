import AppKit
import CormorantBrowser
import CormorantCore
import SwiftUI
import WebKit

struct BrowserWindow: View {
    let store: BrowserStore
    let commands: WindowCommands
    @State private var address = ""
    @State private var submitted = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationSplitView {
            TabList(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                addressBar
                Divider()
                page
                    .overlay(alignment: .bottom) {
                        if let toast = store.toast { ToastView(toast: toast, store: store).padding() }
                    }
            }
        }
        .onChange(of: store.addressFocusRequest) { addressFocused = true }
        .onChange(of: commands.addressFocusRequest) { addressFocused = true }
        // Not over what's being typed, unless it's another tab's address now.
        .onChange(of: store.activeTab?.url, initial: true) { if !addressFocused { showAddress() } }
        .onChange(of: store.activeTab?.id) { showAddress() }
        .onChange(of: store.isComposingNewTab) { showAddress() }
        .onChange(of: addressFocused) { _, focused in
            guard !focused else { return }
            if store.isComposingNewTab {
                store.cancelComposing()
            } else if submitted {
                // What was typed stays until the page it asked for commits.
                submitted = false
            } else {
                showAddress()
            }
        }
        .onChange(of: store.previewedDownload) { _, file in
            guard let file else { return }
            NSWorkspace.shared.open(file)
            store.previewedDownload = nil
        }
        .onChange(of: store.showsDownloads) { _, shows in
            guard shows else { return }
            if let newest = store.downloads.listed.first(where: { $0.status == .finished }) {
                NSWorkspace.shared.activateFileViewerSelecting([newest.fileURL])
            }
            store.showsDownloads = false
        }
        .alert("Couldn't read saved tabs.", isPresented: Binding(get: { store.loadFailure != nil }, set: { _ in })) {
            Button("Start Fresh") { store.startFresh() }
        } message: {
            if let name = store.loadFailure?.keptCopyName {
                Text("A copy was kept at \(name).")
            } else {
                Text("No copy could be kept. Starting fresh replaces them.")
            }
        }
    }

    @ViewBuilder private var page: some View {
        if let session = store.activeSession, !store.isComposingNewTab {
            WebViewHost(webView: session.webView)
                .overlay(alignment: .top) {
                    if session.isLoading { ProgressView(value: session.progress).progressViewStyle(.linear) }
                }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    /// In the page's column rather than the window's toolbar, where focus doesn't reach a text field.
    private var addressBar: some View {
        let session = store.isComposingNewTab ? nil : store.activeSession
        return HStack(spacing: 8) {
            Button("Back", systemImage: "chevron.left") { session?.goBack() }
                .disabled(session?.canGoBack != true)
            Button("Forward", systemImage: "chevron.right") { session?.goForward() }
                .disabled(session?.canGoForward != true)
            Button(session?.isLoading == true ? "Stop" : "Reload",
                   systemImage: session?.isLoading == true ? "xmark" : "arrow.clockwise") { session?.reloadOrStop() }
                .disabled(session == nil)
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit {
                    submitted = true
                    store.submit(address)
                    addressFocused = false
                }
                .onExitCommand { addressFocused = false }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func showAddress() {
        address = store.isComposingNewTab ? "" : store.activeTab?.url?.absoluteString ?? ""
    }
}

private struct TabList: View {
    let store: BrowserStore

    var body: some View {
        List(selection: Binding(get: { store.state.activeTabID }, set: { if let id = $0 { store.activate(id) } })) {
            if !store.pinnedTabs.isEmpty {
                Section("Pinned") {
                    ForEach(store.pinnedTabs) { TabRow(tab: $0, store: store) }
                }
            }
            Section {
                Button("New Tab", systemImage: "plus") { store.newTab() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                // Newest first and staying put: the store's order is the last viewed.
                ForEach(store.unpinnedTabs.sorted { $0.createdAt > $1.createdAt }) { TabRow(tab: $0, store: store) }
            }
        }
        .safeAreaInset(edge: .bottom) { DownloadsMenu(downloads: store.downloads).padding(10) }
    }
}

private struct TabRow: View {
    let tab: CormorantCore.Tab
    let store: BrowserStore

    var body: some View {
        Label {
            Text(tab.customTitle ?? (tab.title.isEmpty ? tab.url?.host() ?? "New Tab" : tab.title))
                .lineLimit(1)
        } icon: {
            if let icon = store.favicons.icon(for: tab.url) {
                Image(decorative: icon, scale: 2).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "globe")
            }
        }
        .tag(tab.id)
        .contextMenu {
            if tab.isPinned {
                Button("Unpin") { store.unpin(tab.id) }
            } else if store.canPin(tab.id) {
                Button("Pin") { store.pin(tab.id) }
            }
            Divider()
            Button("Close Tab") { store.close(tab.id) }
        }
    }
}

private struct DownloadsMenu: View {
    let downloads: DownloadCenter

    var body: some View {
        HStack {
            Menu("Downloads", systemImage: "arrow.down.circle") {
                if downloads.listed.isEmpty { Text("No Downloads") }
                ForEach(downloads.listed) { item in
                    Button(item.filename) { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                        .disabled(item.status != .finished)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .fixedSize()
            Spacer()
        }
    }
}

private struct ToastView: View {
    let toast: Toast
    let store: BrowserStore

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
            ForEach(toast.actions) { action in
                Button(action.title) {
                    action.perform()
                    store.dismissToast(toast.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .onHover { store.holdToast($0) }
    }
}

/// The session owns its web view, so the one on screen is swapped in rather than rebuilt.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
