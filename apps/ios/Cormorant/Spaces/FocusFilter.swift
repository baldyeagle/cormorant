import AppIntents
import CormorantCore
import Foundation
import Observation
import UIKit

/// The Space a Focus filter sends links from other apps to, while a Focus with Cormorant's filter is
/// on: set by the system through `SpaceFocusFilter`, read by `BrowserStore` whenever a link arrives,
/// and by Edit Space. The app learns only that its filter is on and which Space it names, not which
/// Focus turned it on. Kept in the app group's defaults (`FocusFilterSpace`), so it survives the app
/// being killed; the system calls the filter again when the Focus ends.
@MainActor
@Observable
final class FocusFilterSettings {
    /// The app's: in the app group's defaults, set by the system.
    static let shared = FocusFilterSettings(defaults: AppGroupStorage.defaults, followsSystem: true)

    /// The filter's Space; nil while no Focus with the filter is on. May name a Space since deleted or
    /// archived: `BrowserState.destinationForLink` then falls back to the Space last used.
    private(set) var spaceID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    /// Asks the system for the filter in force on `refresh()`. Off for UI tests, which set it themselves.
    @ObservationIgnored private let followsSystem: Bool
    /// Bumped by each `set`, so an answer to `refresh()` asked for before the system last set the
    /// filter (a Focus starting meanwhile) is dropped rather than undoing it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var asking: Task<Void, Never>?

    init(defaults: UserDefaults, followsSystem: Bool) {
        self.defaults = defaults
        self.followsSystem = followsSystem
        spaceID = FocusFilterSpace.read(from: defaults)
    }

    func set(_ spaceID: UUID?) {
        generation += 1
        FocusFilterSpace.write(spaceID, to: defaults)
        if self.spaceID != spaceID { self.spaceID = spaceID }
    }

    /// On launch and foreground: what was stored (the system may have called the filter in another
    /// launch), then, once the system answers, the filter actually in force, in case a call was missed.
    /// One question at a time; an answer the system has overtaken by setting the filter is dropped.
    func refresh() {
        let stored = FocusFilterSpace.read(from: defaults)
        if spaceID != stored { spaceID = stored }
        guard followsSystem else { return }
        asking?.cancel()
        let asked = generation
        asking = Task {
            guard let current = try? await SpaceFocusFilter.current, !Task.isCancelled, generation == asked else { return }
            set(current.space?.id)
        }
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
