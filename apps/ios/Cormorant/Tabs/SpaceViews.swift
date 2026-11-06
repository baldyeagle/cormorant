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
/// when that isn't the default. The tabs button's long-press menu and the switcher's title menu.
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
/// switch. Past five it scrolls, fading out at an edge with more Spaces beyond it, and keeps the
/// active Space in sight.
struct SpaceStrip: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSwitch: (UUID) -> Void
    /// Grows with Dynamic Type only so far: five of them, Search Tabs and New Tab still share the bar.
    @ScaledMetric(relativeTo: .body) private var scaledGlyph: CGFloat = 32
    private var glyph: CGFloat { min(scaledGlyph, 40) }
    /// Which edges have Spaces beyond them, as the strip last scrolled.
    @State private var overflow = Overflow()
    @State private var position = ScrollPosition(idType: UUID.self)

    /// How many fit beside Search Tabs and New Tab on the narrowest phone (375pt), at any text size.
    private static let visibleCount = 5

    /// Each icon's tap target: 44pt wide (so five still leave room for Search Tabs and New Tab at the
    /// largest text sizes, where the disc grows to 40pt inside it) and at least 44pt high.
    private let slot: CGFloat = 44
    private var slotHeight: CGFloat { max(glyph + 4, 44) }
    /// How far an edge fades: nearly the whole slot there, so the icon in it shows clearly faded.
    private let fade: CGFloat = 40

    struct Overflow: Equatable {
        var leading = false
        var trailing = false
    }

    var body: some View {
        let spaces = store.state.switchableSpaces
        if spaces.count > Self.visibleCount {
            ScrollView(.horizontal) {
                glyphs(spaces).scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("SpaceStripScroller")
            .scrollPosition($position, anchor: .center)
            .frame(width: CGFloat(Self.visibleCount) * slot)
            .onScrollGeometryChange(for: Overflow.self) { geometry in
                let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                let hidden = geometry.contentSize.width - geometry.containerSize.width
                return Overflow(leading: offset > 1, trailing: offset < hidden - 1)
            } action: { _, new in
                overflow = new
            }
            .mask { edgeFade }
            .onAppear { reveal(store.state.activeSpaceID, animated: false) }
            // The title menu switches too, to a Space that may be out of sight here; a Space added or
            // archived shifts the others.
            .onChange(of: store.state.activeSpaceID) { _, id in reveal(id, animated: true) }
            .onChange(of: spaces.map(\.id)) { _, _ in reveal(store.state.activeSpaceID, animated: true) }
            #if DEBUG
            .onChange(of: overflow, initial: true) { _, new in Self.reportedOverflow = new }
            .onDisappear { Self.reportedOverflow = nil }
            #endif
        } else {
            glyphs(spaces)
        }
    }

    /// Opaque where the strip shows, fading to clear at each edge with Spaces beyond it.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(overflow.leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(overflow.trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: overflow)
    }

    /// Scrolls the Space to the middle of the strip (as near as its ends allow).
    private func reveal(_ id: UUID, animated: Bool) {
        if animated, !reduceMotion {
            withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: id, anchor: .center) }
        } else {
            position.scrollTo(id: id, anchor: .center)
        }
    }

    #if DEBUG
    /// The edges the strip last faded, for UI tests (`UITestingProbes`): "none", "leading", "trailing"
    /// or "both"; nil while no strip scrolls.
    static var reportedOverflow: Overflow?
    #endif

    private func glyphs(_ spaces: [Space]) -> some View {
        // Each button spans its whole slot, so a tap near an icon, or between two, still lands.
        HStack(spacing: 0) {
            ForEach(spaces) { space in
                let isActive = space.id == store.state.activeSpaceID
                // A tap switches; a long press opens the menu, anchored to the icon as the tabs button's
                // is. Not a context menu: that lifts the icon out of the strip (and on a device slid it
                // toward the strip's middle) for its preview.
                Menu {
                    Button("Edit \(space.name)", systemImage: "pencil") { store.showManageSpaces(editing: space.id) }
                    Button("Manage Spaces", systemImage: "square.stack") { store.showManageSpaces() }
                } label: {
                    Image(systemName: space.icon.rawValue)
                        .font(.system(size: glyph * 0.5, weight: .medium))
                        .foregroundStyle(isActive ? Color.white : space.color.color)
                        .frame(width: glyph, height: glyph)
                        .background { if isActive { Circle().fill(space.color.color) } }
                        .frame(width: slot, height: slotHeight)
                        .contentShape(.rect)
                } primaryAction: {
                    onSwitch(space.id)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityAction(named: "Edit \(space.name)") { store.showManageSpaces(editing: space.id) }
                .accessibilityAction(named: "Manage Spaces") { store.showManageSpaces() }
                .accessibilityShowsLargeContentViewer {
                    Label(space.name, systemImage: space.icon.rawValue)
                }
                .id(space.id)
                .accessibilityLabel(space.name)
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .accessibilityIdentifier("SpaceStrip")
            }
        }
    }
}
