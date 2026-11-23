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
        // Up behind the status bar too, over the page running under it; the status bar takes the
        // default chrome's style here.
        .background(Color(.launchBackground).ignoresSafeArea())
    }
}
