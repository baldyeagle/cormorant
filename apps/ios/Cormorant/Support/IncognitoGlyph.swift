import CoreGraphics
import SwiftUI
import UIKit

extension IncognitoIcon {
    /// Width over height of the grid every style is drawn on.
    static let aspectRatio: CGFloat = 2

    /// The style's parts, in grid units: lenses (outlined when off, filled when on), the lines around
    /// them (bridge, arms), a brow always filled, and a glint cut out of the lenses when on.
    fileprivate var parts: (lenses: CGPath, lines: CGPath, brow: CGPath?, glint: CGPath?) {
        switch self {
        case .wayfarer:
            (.svg("M3 3.2H14.2L13.2 10.6Q12.7 13 10.2 13H7.1Q4.6 13 4.1 10.6Z M17.8 3.2H29L27.9 10.6Q27.4 13 24.9 13H21.8Q19.3 13 18.8 10.6Z"),
             .svg("M14.2 4.6Q16 3.6 17.8 4.6 M3 3.2L1 4.4 M29 3.2L31 4.4"),
             .svg("M2.6 2.2H14.6V4H2.6Z M17.4 2.2H29.4V4H17.4Z"), nil)
        case .aviator:
            (.svg("M3.2 4.2Q3.2 2.6 5.2 2.6H12.6Q14.4 2.6 14 5Q13.2 12.4 9 12.8Q4 12.8 3.2 7.2Z M28.8 4.2Q28.8 2.6 26.8 2.6H19.4Q17.6 2.6 18 5Q18.8 12.4 23 12.8Q28 12.8 28.8 7.2Z"),
             .svg("M12.6 2.6H19.4 M14 5.6Q16 4.6 18 5.6 M3.2 3.6L1 4.6 M28.8 3.6L31 4.6"), nil, nil)
        case .round:
            (.roundLenses, .svg("M14 7Q16 5.4 18 7 M4 7L1.2 5.8 M28 7L30.8 5.8"), nil, nil)
        case .catEye:
            (.svg("M1.6 2.2L5.2 3.6H13.4Q15 3.6 14.6 6Q13.6 12 9.2 12Q4.6 12 3.6 7.6Q3 5 1.6 2.2Z M30.4 2.2L26.8 3.6H18.6Q17 3.6 17.4 6Q18.4 12 22.8 12Q27.4 12 28.4 7.6Q29 5 30.4 2.2Z"),
             .svg("M14.6 5.2Q16 4.2 17.4 5.2"), nil, nil)
        case .shield:
            (.svg("M2.2 4.2Q16 0.8 29.8 4.2L28.8 9.2Q28 12.4 23.2 12.4Q19.2 12.4 17.4 9.4Q16 7.8 14.6 9.4Q12.8 12.4 8.8 12.4Q4 12.4 3.2 9.2Z"),
             .svg("M2.2 4.2L0.8 5.4 M29.8 4.2L31.2 5.4"), nil, nil)
        case .browline:
            (.svg("M3.4 5.2Q3.8 12.4 8.8 12.4Q13.4 12.4 13.8 5.2Z M18.2 5.2Q18.6 12.4 23.2 12.4Q28.2 12.4 28.6 5.2Z"),
             .svg("M14.2 4.6Q16 3.4 17.8 4.6 M2.6 3L1 4.2 M29.4 3L31 4.2"),
             .svg("M2.6 2.4H14.4V5.4H2.6Z M17.6 2.4H29.4V5.4H17.6Z"), nil)
        case .classic:
            (.svg("M3.2 4Q3.2 12.6 8.8 12.6Q14 12.6 14 4Z M18 4Q18 12.6 23.2 12.6Q28.8 12.6 28.8 4Z"),
             .svg("M1.5 4H30.5"), nil, nil)
        case .glint:
            (.roundLenses, .svg("M14 7Q16 5.4 18 7 M4 7L1.2 5.8 M28 7L30.8 5.8"), nil,
             .svg("M6.6 7.4L9.2 4.8 M20.6 7.4L23.2 4.8"))
        }
    }

    /// The style at `width` points (half as tall), in `color`: filled lenses when `isOn`, else outlined.
    /// For menus, which draw SwiftUI images as one-color templates.
    func image(width: CGFloat, isOn: Bool, color: UIColor = .label) -> UIImage {
        let size = CGSize(width: width, height: width / Self.aspectRatio)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            draw(in: context.cgContext, size: size, isOn: isOn, color: color.cgColor)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    fileprivate func draw(in context: CGContext, size: CGSize, isOn: Bool, color: CGColor) {
        let scale = size.width / 32
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let parts = parts
        if let brow = parts.brow {
            context.addPath(brow)
            context.fillPath()
        }
        context.addPath(parts.lenses)
        context.drawPath(using: isOn ? .fillStroke : .stroke)
        context.addPath(parts.lines)
        context.strokePath()
        if isOn, let glint = parts.glint {
            context.setBlendMode(.clear)
            context.setLineWidth(1.3)
            context.addPath(glint)
            context.strokePath()
        }
    }
}

/// The picked Incognito sunglasses, filling the width it's given (half as tall), in the foreground
/// color. Hidden from VoiceOver: whatever shows it says "Incognito".
struct IncognitoGlyph: View {
    let icon: IncognitoIcon
    var isOn = true

    var body: some View {
        // The foreground style through a mask: a CGContext needs a color, and the style may be a
        // material or hierarchical one.
        Rectangle()
            .fill(.foreground)
            .mask {
                Canvas { context, size in
                    context.withCGContext { icon.draw(in: $0, size: size, isOn: isOn, color: UIColor.white.cgColor) }
                }
            }
            .aspectRatio(IncognitoIcon.aspectRatio, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

// MARK: - Paths

private extension CGPath {
    /// Both round lenses: circles of radius 5 at (9, 8) and (23, 8).
    static var roundLenses: CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 4, y: 3, width: 10, height: 10))
        path.addEllipse(in: CGRect(x: 18, y: 3, width: 10, height: 10))
        return path
    }

    /// A path from SVG path data using only absolute M, L, H, V, Q and Z, as the styles above do.
    static func svg(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var number = ""
        for character in data {
            if character.isLetter {
                if !number.isEmpty { tokens.append(number); number = "" }
                tokens.append(String(character))
            } else if character == " " || character == "," {
                if !number.isEmpty { tokens.append(number); number = "" }
            } else if character == "-", !number.isEmpty {
                tokens.append(number)
                number = "-"
            } else {
                number.append(character)
            }
        }
        if !number.isEmpty { tokens.append(number) }

        var index = 0
        var command = "M"
        func next() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0)
        }
        while index < tokens.count {
            if tokens[index].first?.isLetter == true {
                command = tokens[index]
                index += 1
                if command == "Z" {
                    path.closeSubpath()
                    continue
                }
            }
            let current = path.isEmpty ? .zero : path.currentPoint
            switch command {
            case "M":
                path.move(to: CGPoint(x: next(), y: next()))
                command = "L"
            case "L": path.addLine(to: CGPoint(x: next(), y: next()))
            case "H": path.addLine(to: CGPoint(x: next(), y: current.y))
            case "V": path.addLine(to: CGPoint(x: current.x, y: next()))
            case "Q":
                let control = CGPoint(x: next(), y: next())
                path.addQuadCurve(to: CGPoint(x: next(), y: next()), control: control)
            default:
                index += 1
            }
        }
        return path
    }
}

extension UIColor {
    /// Incognito's black: Vialumi's dark background, #030712, in light mode and dark.
    static let incognitoBackground = UIColor(red: 3 / 255, green: 7 / 255, blue: 18 / 255, alpha: 1)
}

extension Color {
    static let incognitoBackground = Color(uiColor: .incognitoBackground)
}
