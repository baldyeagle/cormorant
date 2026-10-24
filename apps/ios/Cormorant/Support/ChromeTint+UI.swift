import CormorantCore
import SwiftUI
import UIKit

extension TabSession {
    /// The chrome's tint for this tab's page in `colorScheme`, or nil for the default chrome.
    func chromeTint(in colorScheme: ColorScheme) -> ChromeTint? {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return ChromeTint(themeColor: RGBColor(themeColor, in: traits),
                          pageBackground: RGBColor(underPageColor, in: traits),
                          defaultBackground: RGBColor(UIColor(resource: .launchBackground), in: traits) ?? .white)
    }
}

extension RGBColor {
    /// `color` resolved for `traits`, in (extended) sRGB.
    init?(_ color: UIColor?, in traits: UITraitCollection) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard let color, color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return nil }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color {
    init(_ color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension ChromeTint {
    /// Text and icons drawn on the tint.
    var foregroundColor: Color {
        Color(foreground == .light ? RGBColor.white : RGBColor.ink)
    }

    /// The scheme whose system foregrounds (status bar, glass highlights) read on the tint.
    var colorScheme: ColorScheme {
        foreground == .light ? .dark : .light
    }
}

extension EnvironmentValues {
    /// The active page's chrome tint; nil for the default chrome.
    @Entry var chromeTint: ChromeTint?
}
