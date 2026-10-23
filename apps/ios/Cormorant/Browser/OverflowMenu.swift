import CormorantBlocking
import SwiftUI
import UIKit

/// Share, copy, per-site blocking, and settings.
struct OverflowMenu: View {
    @Environment(BrowserStore.self) private var store
    let url: URL?
    let showSettings: () -> Void

    var body: some View {
        Menu {
            if let url {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                if store.blocking.preferences.isEnabled, let host = url.host() {
                    if store.blocking.isBlocking(host: host) {
                        Button("Reload Without Blockers", systemImage: "shield.slash") {
                            store.toggleBlockingForActiveSite()
                        }
                    } else {
                        Button("Enable Blockers for this site", systemImage: "checkmark.shield") {
                            store.toggleBlockingForActiveSite()
                        }
                    }
                }
                Divider()
            }
            Button("Settings", systemImage: "gearshape", action: showSettings)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}
