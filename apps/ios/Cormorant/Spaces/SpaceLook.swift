import CormorantCore
import SwiftUI

extension Swatch {
    /// For VoiceOver.
    var name: String { rawValue.capitalized }
}

extension SpaceIcon {
    /// For VoiceOver.
    var name: String {
        switch self {
        case .house: "House"
        case .briefcase: "Briefcase"
        case .hammer: "Hammer"
        case .airplane: "Airplane"
        case .book: "Book"
        case .cart: "Cart"
        case .heart: "Heart"
        case .leaf: "Leaf"
        case .gameController: "Game Controller"
        case .musicNote: "Music Note"
        case .graduationCap: "Graduation Cap"
        case .camera: "Camera"
        }
    }
}

/// A Space's icon, white on a rounded square of its color. Takes the icon and color rather than a
/// Space, so New and Edit Space can show a look before it's saved; `SpaceBadge` draws a saved one.
struct SpaceIconBadge: View {
    let icon: SpaceIcon
    let color: Swatch
    var side: CGFloat = 32
    /// The symbol's point size as a fraction of `side`.
    var symbolScale: CGFloat = 0.5

    var body: some View {
        Image(systemName: icon.rawValue)
            .font(.system(size: side * symbolScale, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.color, in: .rect(cornerRadius: side * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The top of New and Edit Space: the Space's badge and name over the bottom bar as it will look
/// there, on a wash of its color: the tab count takes the color, and the glass the bar's trace of it.
struct SpaceBarPreview: View {
    let name: String
    let icon: SpaceIcon
    let color: Swatch
    let tabCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            SpaceIconBadge(icon: icon, color: color, side: 48)
            Text(name.isEmpty ? "New Space" : name)
                .font(.headline)
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .padding(.horizontal)
            bar
                .padding(.top, 14)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [color.color.opacity(colorScheme == .dark ? 0.34 : 0.22),
                                    color.color.opacity(colorScheme == .dark ? 0.10 : 0.05)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.snappy, value: color)
        .animation(.snappy, value: icon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue("\(name.isEmpty ? "New Space" : name), \(icon.name) icon, \(color.name)")
    }

    /// The bar's three controls, a little smaller than in the browser.
    private var bar: some View {
        let glass = Glass.regular.tint(color.barTint(in: colorScheme))
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Text(tabCount < 100 ? "\(tabCount)" : "∞")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(color.color)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 21, minHeight: 21)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(color.color, lineWidth: 1.5))
                    .frame(width: 42, height: 42)
                    .glassEffect(glass, in: .circle)
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 80, height: 42)
                    .glassEffect(glass, in: .capsule)
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 42, height: 42)
                    .glassEffect(glass, in: .circle)
            }
        }
    }
}

/// The twelve icons, six to a row; the chosen one filled with the Space's color.
struct SpaceIconPicker: View {
    @Binding var icon: SpaceIcon
    let color: Swatch

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            ForEach(SpaceIcon.allCases, id: \.self) { option in
                let isChosen = option == icon
                Button { icon = option } label: {
                    Image(systemName: option.rawValue)
                        .font(.title3)
                        .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(isChosen ? AnyShapeStyle(color.color) : AnyShapeStyle(.fill.tertiary),
                                    in: .rect(cornerRadius: 12, style: .continuous))
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

/// The eight colors in a row; the chosen one ringed.
struct SpaceColorPicker: View {
    @Binding var color: Swatch

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Swatch.allCases, id: \.self) { option in
                let isChosen = option == color
                Button { color = option } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 28, height: 28)
                        .padding(4)
                        .overlay(Circle().stroke(option.color, lineWidth: 2.5).opacity(isChosen ? 1 : 0))
                        .frame(maxWidth: .infinity)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
