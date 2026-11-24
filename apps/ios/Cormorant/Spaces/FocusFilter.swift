import AppIntents
import CormorantBrowser
import CormorantCore
import Foundation
import Observation
import UIKit

extension FocusFilterSettings {
    /// The app's: in the app group's defaults, set by the system.
    static let shared = FocusFilterSettings(defaults: AppGroupStorage.defaults) {
        (try? await SpaceFocusFilter.current).map { $0.space?.id }
    }
}

/// Cormorant's Focus filter: Settings › Focus › (a Focus) › Add Filter › Cormorant. One setting, the
/// Space that links from other apps open in while that Focus is on. The system calls `perform()` as
/// the Focus starts (with the Space chosen) and as it ends (with none).
struct SpaceFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Open Links in a Space"
    static let description = IntentDescription(
        "Choose the Space that links from other apps open in while this Focus is on. When the Focus ends, they open in the last Space you used.")

    @Parameter(title: "Space")
    var space: SpaceEntity?

    var displayRepresentation: DisplayRepresentation {
        guard let space else { return DisplayRepresentation(title: "Links open in the last Space you used") }
        return DisplayRepresentation(title: "Links open in \(space.name)", image: space.image)
    }

    func perform() async throws -> some IntentResult {
        await FocusFilterSettings.shared.set(space?.id)
        return .result()
    }
}

/// A Space, as the Focus filter's setting lists it: the Spaces you can switch to, from the summary the
/// app keeps for the share extension (`SpacesSummaryFile`), so it's there without loading every tab.
struct SpaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    static let defaultQuery = SpaceEntityQuery()

    let id: UUID
    let name: String
    let icon: SpaceIcon
    let color: Swatch

    init(_ entry: SpacesSummary.Entry) {
        id = entry.id
        name = entry.name
        icon = entry.icon
        color = entry.color
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: image)
    }

    /// The Space's badge, white on its color, as the app draws it.
    var image: DisplayRepresentation.Image? {
        Self.badgePNG(icon: icon, color: color).map { DisplayRepresentation.Image(data: $0) }
    }

    nonisolated static func badgePNG(icon: SpaceIcon, color: Swatch) -> Data? {
        let side: CGFloat = 32
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let symbol = UIImage(systemName: icon.rawValue,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let rgb = color.rgb
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
            UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.alpha).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: side * 0.27).fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                       width: size.width, height: size.height))
            }
        }
    }
}

struct SpaceEntityQuery: EntityQuery {
    /// Every ID asked for comes back, those of Spaces not in the summary (archived since, or not yet
    /// summed up) as "Unavailable Space": the filter keeps naming the Space, so its links go there
    /// again once it's back, rather than the filter reading as naming none.
    func entities(for identifiers: [UUID]) async throws -> [SpaceEntity] {
        let spaces = Self.spaces()
        return identifiers.map { id in
            spaces.first { $0.id == id }
                ?? SpaceEntity(SpacesSummary.Entry(id: id, name: "Unavailable Space", icon: .house, color: .gray))
        }
    }

    func suggestedEntities() async throws -> [SpaceEntity] { Self.spaces() }

    /// None until the app has written its summary (it does at launch).
    private static func spaces() -> [SpaceEntity] {
        (SpacesSummaryFile(appGroup: AppGroup.identifier)?.read()?.spaces ?? []).map(SpaceEntity.init)
    }
}
