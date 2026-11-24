import Foundation
import WebKit

/// A link preview's web view on its way to becoming a tab, with what the tab needs to carry on from
/// where the preview got to.
struct LinkPreviewHandoff {
    let webView: WKWebView
    let contentController: WKUserContentController
    let appliedHost: String?
    let appliedListsVersion: Int?
    let requestedContentMode: WKWebpagePreferences.ContentMode
    let effectiveContentMode: WKWebpagePreferences.ContentMode
    let requestedURL: URL

    init(webView: WKWebView, contentController: WKUserContentController, appliedHost: String?,
                appliedListsVersion: Int?, requestedContentMode: WKWebpagePreferences.ContentMode,
                effectiveContentMode: WKWebpagePreferences.ContentMode, requestedURL: URL) {
        self.webView = webView
        self.contentController = contentController
        self.appliedHost = appliedHost
        self.appliedListsVersion = appliedListsVersion
        self.requestedContentMode = requestedContentMode
        self.effectiveContentMode = effectiveContentMode
        self.requestedURL = requestedURL
    }
}
