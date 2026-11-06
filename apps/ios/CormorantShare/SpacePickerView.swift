import CormorantCore
import SwiftUI
import UIKit

/// What the share sheet asks before handing a link to Cormorant, with more than one Space: which Space
/// it opens in. Starts on the Space it would open in anyway (a Focus filter's, else the one last
/// used); only a Space picked here travels with the link, so one left alone opens wherever links go
/// when the app gets it.
struct SpacePickerView: View {
    let link: URL
    let title: String?
    let summary: SpacesSummary
    /// The Space it opens in unless another is picked.
    let defaultSpace: SpacesSummary.Entry
    /// A Focus filter chose `defaultSpace`.
    let focusChoseDefault: Bool
    /// Open, with the Space picked (nil if none was).
    let onOpen: (UUID?) -> Void
    let onCancel: () -> Void

    @State private var picked: UUID?

    private var shown: SpacesSummary.Entry { picked.flatMap(summary.space) ?? defaultSpace }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LinkRow(link: link, title: title)
                }
                Section {
                    spaceMenu
                } header: {
                    Text("Space")
                } footer: {
                    if picked == nil, focusChoseDefault {
                        Text("A Focus filter sends links to \(defaultSpace.name) now.")
                    }
                }
            }
            .navigationTitle("Cormorant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { onOpen(picked) } label: { Text("Open") }
                        .accessibilityIdentifier("ShareOpen")
                }
            }
        }
    }

    private var spaceMenu: some View {
        Menu {
            Picker("Space", selection: Binding(get: { shown.id }, set: { picked = $0 })) {
                ForEach(summary.spaces) { space in
                    Label {
                        Text(space.name)
                    } icon: {
                        Image(uiImage: ShareBadge.menuImage(for: space)).renderingMode(.original)
                    }
                    .tag(space.id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                ShareBadge(icon: shown.icon, color: shown.color)
                Text(shown.name)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        // The name in the text color, as a value is, not the tint of a button.
        .tint(.primary)
        .accessibilityLabel("Space")
        .accessibilityValue(shown.name)
        .accessibilityHint("Chooses the Space the link opens in")
        .accessibilityIdentifier("ShareSpaceMenu")
    }
}

/// The link being shared: its page title when the sharing app gave one, and its host.
private struct LinkRow: View {
    let link: URL
    let title: String?

    private var host: String {
        let host = link.host() ?? link.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(host.first.map { String($0).uppercased() } ?? "?")
                .font(.title3.weight(.bold))
                // Black on white in light mode, the reverse in dark, so it stands off the row either way.
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 40, height: 40)
                .background(Color(uiColor: .label), in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? host)
                    .font(.headline)
                    .lineLimit(2)
                if title != nil {
                    Text(host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A Space's icon, white on a rounded square of its color, as the app draws it.
struct ShareBadge: View {
    let icon: SpaceIcon
    let color: Swatch
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30

    var body: some View {
        Image(systemName: icon.rawValue)
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color(uiColor: color.uiColor), in: .rect(cornerRadius: side * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }

    /// The badge for a menu, which draws SwiftUI images as one-color templates: drawn here in full.
    static func menuImage(for space: SpacesSummary.Entry) -> UIImage {
        let side: CGFloat = 24
        let symbol = UIImage(systemName: space.icon.rawValue,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            space.color.uiColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 6.5).fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                       width: size.width, height: size.height))
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}

private extension Swatch {
    var uiColor: UIColor { UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.alpha) }
}
