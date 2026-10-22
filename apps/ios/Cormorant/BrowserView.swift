import CormorantCore
import SwiftUI
import WebKit

/// Placeholder browser shell: one web view, a bottom address bar, back/forward.
struct BrowserView: View {
    @State private var model = BrowserModel()
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        WebViewContainer(webView: model.webView)
            .ignoresSafeArea(.container, edges: .top)
            .overlay {
                if model.tab.url == nil {
                    Text("Cormorant")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .onAppear { addressFocused = true }
            .onChange(of: model.tab.url) { _, newURL in
                if !addressFocused { address = newURL?.absoluteString ?? "" }
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .opacity(model.isLoading ? 1 : 0)

            HStack(spacing: 12) {
                Button("Back", systemImage: "chevron.backward", action: model.goBack)
                    .disabled(!model.canGoBack)
                Button("Forward", systemImage: "chevron.forward", action: model.goForward)
                    .disabled(!model.canGoForward)

                TextField("Search or enter address", text: $address)
                    .focused($addressFocused)
                    .keyboardType(.webSearch)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        model.submit(address)
                        addressFocused = false
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)

                Button(
                    model.isLoading ? "Stop" : "Reload",
                    systemImage: model.isLoading ? "xmark" : "arrow.clockwise",
                    action: model.reloadOrStop
                )
                .disabled(model.tab.url == nil)
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

/// Hosts the model-owned `WKWebView` in SwiftUI.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    BrowserView()
}
