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
    let space: Space
    let side: CGFloat

    var body: some View {
        Image(systemName: space.icon.rawValue)
            .font(.system(size: side * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(space.color.color, in: .rect(cornerRadius: side * 0.27))
            .accessibilityHidden(true)
    }
}
