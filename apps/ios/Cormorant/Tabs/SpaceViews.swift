import CormorantCore
import SwiftUI
import UIKit

extension Swatch {
    var color: Color { Color(rgb) }
    /// The trace of the color the bottom bar's glass takes: 10% in light mode, 12% in dark so it
    /// survives the black (16% turned orange's controls brown). The bar and New/Edit Space's preview.
    func barTint(in colorScheme: ColorScheme) -> Color { color.opacity(colorScheme == .dark ? 0.12 : 0.10) }

    /// The switcher's wash from the top: 16% in either mode.
    var switcherWash: Color { color.opacity(0.16) }
    var uiColor: UIColor { UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.alpha) }
}

/// A Space's icon, white on a rounded square of its color: the switcher's title, and the Space menus.
struct SpaceBadge: View {
    let space: Space
    @ScaledMetric(relativeTo: .headline) private var side: CGFloat = 24

    var body: some View {
        SpaceIconBadge(icon: space.icon, color: space.color, side: side, symbolScale: 0.55)
    }

    /// Drawn once per look: menus re-evaluate on every state change, a page's title included.
    private static var menuImages: [String: UIImage] = [:]

    /// The badge as a menu image: menus draw SwiftUI images as templates in one color, so it's drawn
    /// here in full and kept as it is.
    static func menuImage(for space: Space) -> UIImage {
        let key = "\(space.icon.rawValue)/\(space.color.rawValue)"
        if let image = menuImages[key] { return image }
        let side: CGFloat = 24
        let symbol = UIImage(systemName: space.icon.rawValue,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            space.color.uiColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 6.5).fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                       width: size.width, height: size.height))
            }
        }
        let original = image.withRenderingMode(.alwaysOriginal)
        menuImages[key] = original
        return original
    }
}

/// The Spaces to switch to, as a checked list for a menu: each with its tab count, and its profile
/// when that isn't the default. The tabs button's long-press menu, and the switcher's title menu and
/// strip menus.
struct SpaceMenuList: View {
    @Environment(BrowserStore.self) private var store
    let onSwitch: (UUID) -> Void

    var body: some View {
        // Toggles of an image and two texts: a menu drops a picker option's subtitle, and the subtitle
        // inside a Label.
        Section {
            ForEach(store.state.switchableSpaces) { space in
                Toggle(isOn: Binding(get: { space.id == store.state.activeSpaceID },
                                     set: { if $0 { onSwitch(space.id) } })) {
                    Image(uiImage: SpaceBadge.menuImage(for: space)).renderingMode(.original)
                    Text(space.name)
                    Text(subtitle(for: space))
                }
            }
        }
    }

    private func subtitle(for space: Space) -> String {
        let count = store.state.tabCount(inSpace: space.id)
        let tabs = count == 1 ? "1 tab" : "\(count) tabs"
        let profile = store.state.profile(forSpace: space.id)
        return profile.isDefault ? tabs : "\(tabs) · \(profile.name) profile"
    }
}

/// The switcher's row of Spaces: each one's icon in its color, the active one on a disc of it. Tap to
/// switch; long-press for every Space, Edit and Manage Spaces. As many as `slots` allows; past that
/// the last slot is ••• (the same menu, on a tap), and the active Space keeps a slot before it.
struct SpaceStrip: View {
    @Environment(BrowserStore.self) private var store
    let onSwitch: (UUID) -> Void
    /// How many icons fit, ••• included (`slots(in:)`).
    let slots: Int
    /// Grows with Dynamic Type only so far: it stays inside its slot.
    @ScaledMetric(relativeTo: .body) private var scaledGlyph: CGFloat = 32
    private var glyph: CGFloat { min(scaledGlyph, 40) }

    /// Each icon's tap target: 44pt wide (the disc grows to 40pt inside it at the largest text sizes)
    /// and at least 44pt high.
    static let slot: CGFloat = 44
    private var slotHeight: CGFloat { max(glyph + 4, 44) }

    /// The slots in `width`: never fewer than two, the active Space and •••.
    static func slots(in width: CGFloat) -> Int { max(2, Int(width / slot)) }

    var body: some View {
        let spaces = store.state.switchableSpaces
        let active = store.state.activeSpaceID
        let (shown, hidesSome) = Self.shown(spaces, active: active, slots: slots)
        // Each button spans its whole slot, so a tap near an icon, or between two, still lands.
        HStack(spacing: 0) {
            ForEach(shown) { space in
                glyph(for: space, isActive: space.id == active)
            }
            if hidesSome, let space = spaces.first(where: { $0.id == active }) ?? shown.first {
                more(editing: space)
            }
        }
    }

    /// Up to `slots` Spaces in their order; past that one slot fewer, for •••, with the active Space
    /// in the last when it would otherwise be hidden.
    private static func shown(_ spaces: [Space], active: UUID, slots: Int) -> (spaces: [Space], hidesSome: Bool) {
        guard spaces.count > slots else { return (spaces, false) }
        var shown = Array(spaces.prefix(max(1, slots - 1)))
        if !shown.contains(where: { $0.id == active }), let activeSpace = spaces.first(where: { $0.id == active }) {
            shown[shown.count - 1] = activeSpace
        }
        return (shown, true)
    }

    /// Every Space, as the tabs button's long press lists them, then the Space's Edit and Manage Spaces.
    @ViewBuilder
    private func menu(editing space: Space) -> some View {
        SpaceMenuList(onSwitch: onSwitch)
        Section {
            Button("Edit \(space.name)", systemImage: "pencil") { store.showManageSpaces(editing: space.id) }
            Button("Manage Spaces", systemImage: "square.stack") { store.showManageSpaces() }
        }
    }

    private func glyph(for space: Space, isActive: Bool) -> some View {
        // A tap switches; a long press opens the menu, anchored to the icon as the tabs button's is.
        // Not a context menu: that lifts the icon out of the strip (and on a device slid it toward
        // the strip's middle) for its preview.
        Menu {
            menu(editing: space)
        } label: {
            Image(systemName: space.icon.rawValue)
                .font(.system(size: glyph * 0.5, weight: .medium))
                .foregroundStyle(isActive ? Color.white : space.color.color)
                .frame(width: glyph, height: glyph)
                .background { if isActive { Circle().fill(space.color.color) } }
                .frame(width: Self.slot, height: slotHeight)
                .contentShape(.rect)
        } primaryAction: {
            onSwitch(space.id)
        }
        .menuStyle(.button)
        // The menu opens upward; the Spaces read top-down in their own order, as in the tabs button's.
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityAction(named: "Edit \(space.name)") { store.showManageSpaces(editing: space.id) }
        .accessibilityAction(named: "Manage Spaces") { store.showManageSpaces() }
        .accessibilityShowsLargeContentViewer {
            Label(space.name, systemImage: space.icon.rawValue)
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("SpaceStrip")
    }

    /// The Spaces that don't fit: a tap opens the menu, its Edit for the active Space.
    private func more(editing space: Space) -> some View {
        Menu {
            menu(editing: space)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: glyph * 0.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.slot, height: slotHeight)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer {
            Label("More Spaces", systemImage: "ellipsis")
        }
        .accessibilityLabel("More Spaces")
        .accessibilityIdentifier("SpaceStripMore")
    }
}
