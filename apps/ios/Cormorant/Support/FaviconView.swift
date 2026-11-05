import SwiftUI

/// A site's icon, or its initial on the host's tint until one arrives. Reads the store itself, so an
/// icon landing re-renders just this view.
struct FaviconView: View {
    let favicons: FaviconStore
    let url: URL?
    let host: String
    var side: CGFloat = 18
    /// In dark mode, a light tile behind the icon, so dark icons with no background of their own
    /// (GitHub's, Apple's) don't vanish into a dark surface.
    var backsDarkIcons = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = favicons.icon(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(backsDarkIcons && colorScheme == .dark ? Color.white.opacity(0.92) : .clear)
            } else {
                HostTint.color(for: host)
                    .overlay {
                        Text(host.first.map { String($0).uppercased() } ?? "")
                            .font(.system(size: side * 0.6, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}
