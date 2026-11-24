import AppKit
import CormorantCore
import SwiftUI

extension Swatch {
    var color: Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }

    /// The window behind the sidebar and page: 15% of the Space's color on light grey, 22% on near
    /// black.
    func windowTint(dark: Bool) -> Color {
        let base = dark ? RGBColor(hex: 0x0B0F19) : RGBColor(hex: 0xECEEF1)
        let amount = dark ? 0.22 : 0.15
        return Color(red: base.red + (rgb.red - base.red) * amount,
                     green: base.green + (rgb.green - base.green) * amount,
                     blue: base.blue + (rgb.blue - base.blue) * amount)
    }

    /// The loading bar: the Space's color, deeper on the light frame, paler on the dark one.
    func loadingColor(dark: Bool) -> Color {
        dark ? Color(red: rgb.red + (1 - rgb.red) * 0.45, green: rgb.green + (1 - rgb.green) * 0.45,
                     blue: rgb.blue + (1 - rgb.blue) * 0.45)
            : Color(red: rgb.red * 0.7, green: rgb.green * 0.7, blue: rgb.blue * 0.7)
    }
}

/// A Space's icon, white on a rounded square of its color.
struct SpaceBadge: View {
    let icon: SpaceIcon
    let color: Swatch
    let side: CGFloat

    init(space: Space, side: CGFloat) {
        self.init(icon: space.icon, color: space.color, side: side)
    }

    init(icon: SpaceIcon, color: Swatch, side: CGFloat) {
        self.icon = icon
        self.color = color
        self.side = side
    }

    var body: some View {
        Image(systemName: icon.rawValue)
            .font(.system(size: side * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.color, in: .rect(cornerRadius: side * 0.27))
            .accessibilityHidden(true)
    }

    /// The badge for a menu item, in its colors: menus draw SwiftUI symbols as templates.
    static func menuImage(for space: Space) -> NSImage {
        MenuImages.image(key: "space/\(space.icon.rawValue)/\(space.color.rawValue)") {
            SpaceBadge(space: space, side: 16)
        }
    }
}

/// A profile's monogram: the first letter of its name, white on a circle of its color. Always a
/// circle, where a Space's icon is a rounded square, so the two never look alike.
struct ProfileMonogram: View {
    let profile: Profile
    let side: CGFloat

    var body: some View {
        Text(profile.monogram)
            .font(.system(size: side * 0.56, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(profile.color.color, in: .circle)
            .accessibilityHidden(true)
    }

    static func menuImage(for profile: Profile) -> NSImage {
        MenuImages.image(key: "profile/\(profile.monogram)/\(profile.color.rawValue)") {
            ProfileMonogram(profile: profile, side: 14)
        }
    }
}

private enum MenuImages {
    private static var cache: [String: NSImage] = [:]

    static func image(key: String, _ content: () -> some View) -> NSImage {
        if let image = cache[key] { return image }
        let renderer = ImageRenderer(content: content())
        renderer.scale = 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
