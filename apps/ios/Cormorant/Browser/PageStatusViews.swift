import SwiftUI
import UIKit

/// Replaces the page when a main-frame load fails.
struct LoadErrorView: View {
    let error: TabSession.LoadError
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can't Open Page", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 6) {
                Text(error.message)
                if let host = error.url?.host() {
                    Text(host).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Shown when a link leads to a file WebKit can't display.
struct DownloadBanner: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("Downloads aren't supported yet")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open in Safari") {
                Self.openInSafari(url)
                onDismiss()
            }
            .font(.subheadline.weight(.semibold))
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// `x-safari-https://` opens Safari even when another browser (possibly this one) is the default.
    private static func openInSafari(_ url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        components.scheme = "x-safari-\(scheme)"
        if let safariURL = components.url { UIApplication.shared.open(safariURL) }
    }
}
