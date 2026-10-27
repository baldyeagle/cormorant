import CormorantCore
import SwiftUI
import UIKit

extension BrowserStore {
    /// The page runs up under the status bar, as in Safari: WebKit carries a fixed header's color up
    /// behind the clock, and the scroll view's soft edge effect keeps the clock legible over content.
    /// With the setting off, the page stops below the status bar, which sits on the default strip.
    var pageRunsUnderStatusBar: Bool { settings.pageUnderStatusBar }

    /// What's behind the status bar for the tab on screen: its page's background, nil for the default
    /// chrome. Also nil with the setting off, away from a page (the empty state, a load error), which
    /// draw their own backgrounds, and while the page's color is from the other appearance (it was
    /// just switched): until it's re-read, the system's own style is the better guess.
    func statusBarTint(in colorScheme: ColorScheme) -> ChromeTint? {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        guard settings.pageUnderStatusBar, activeTab?.url != nil,
              let session = activeSession, session.loadError == nil,
              session.pageBackgroundStyle == style else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: style)
        return ChromeTint(pageBackground: RGBColor(session.pageBackground, in: traits),
                          defaultBackground: .launchBackground(in: colorScheme))
    }

    /// The color behind the status bar, for anything that has to match it: the iPhone Duo's status-bar
    /// column, and the backdrop a card fades in as it grows into the page.
    func stripColor(in colorScheme: ColorScheme) -> Color {
        Color(statusBarTint(in: colorScheme)?.background ?? .launchBackground(in: colorScheme))
    }

    /// `stripColor(in:)` for UIKit callers.
    func stripUIColor(for style: UIUserInterfaceStyle) -> UIColor {
        let colorScheme: ColorScheme = style == .dark ? .dark : .light
        let color = statusBarTint(in: colorScheme)?.background ?? .launchBackground(in: colorScheme)
        return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
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

    /// The default chrome: Vialumi's white, or #030712 in dark mode.
    static func launchBackground(in colorScheme: ColorScheme) -> RGBColor {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return RGBColor(UIColor(resource: .launchBackground), in: traits) ?? .white
    }
}

extension Color {
    init(_ color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension ChromeTint {
    /// The scheme whose system foregrounds (the status bar) read on the tint.
    var colorScheme: ColorScheme {
        foreground == .light ? .dark : .light
    }
}
