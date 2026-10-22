import CormorantCore
import Observation
import WebKit

/// Owns the single placeholder web view and mirrors its KVO state for SwiftUI.
@Observable
final class BrowserModel {
    let webView: WKWebView
    private(set) var tab = Tab()
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        observe()
    }

    func submit(_ input: String) {
        guard let url = AddressInput.url(for: input) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    private func observe() {
        // WKWebView posts KVO changes on the main thread.
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.isLoading = web.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.progress = web.estimatedProgress }
            },
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    self?.tab.url = web.url
                    self?.tab.lastViewedAt = .now
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.tab.title = web.title ?? "" }
            },
        ]
    }
}
