import Foundation

// MARK: - Links from other apps (a Space picked in the share extension, a Focus filter's Space)

/// Why a link from another app opened in the Space it did.
public enum LinkDestinationReason: Sendable, Equatable {
    /// The share extension was told to open it there.
    case requested
    /// A Focus filter sends links from other apps there.
    case focus
    /// It's the Space last used (the active one).
    case lastUsed
}

extension BrowserState {
    /// Where a link from another app opens: the Space picked for it in the share extension, if it can
    /// still be switched to; else the Focus filter's Space, if that can; else the Space last used. A
    /// deleted or archived Space falls through to the next.
    public func destinationForLink(requestedSpace: UUID?, focusSpace: UUID?)
        -> (spaceID: UUID, reason: LinkDestinationReason) {
        if let requestedSpace, space(requestedSpace)?.isArchived == false { return (requestedSpace, .requested) }
        if let focusSpace, space(focusSpace)?.isArchived == false { return (focusSpace, .focus) }
        return (activeSpaceID, .lastUsed)
    }
}

// MARK: - Spaces summary (the share extension and the Focus filter's Space list)

/// The Spaces you can switch to, as the share extension and the Focus filter's Space list show them.
/// The app writes it to a small file of its own (`SpacesSummaryFile`) whenever it changes, so neither
/// has to read the browser state file, which holds every tab and up to 2,000 archived ones (and which
/// a reader that can't decode it must never touch).
public struct SpacesSummary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public var name: String
        public var icon: SpaceIcon
        public var color: Swatch

        public init(id: UUID, name: String, icon: SpaceIcon, color: Swatch) {
            self.id = id
            self.name = name
            self.icon = icon
            self.color = color
        }

        public init(_ space: Space) {
            self.init(id: space.id, name: space.name, icon: space.icon, color: space.color)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try container.decode(UUID.self, forKey: .id),
                      name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                      icon: try container.decodeIfPresent(SpaceIcon.self, forKey: .icon) ?? .house,
                      color: try container.decodeIfPresent(Swatch.self, forKey: .color) ?? .teal)
        }
    }

    /// Version of the file's shape. Readers take what they understand of any version.
    public static let currentVersion = 1

    /// Switchable Spaces, in order.
    public var spaces: [Entry]
    /// The Space last used; nil only in a file that doesn't say.
    public var activeSpaceID: UUID?

    public init(spaces: [Entry], activeSpaceID: UUID?) {
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
    }

    public init(_ state: BrowserState) {
        self.init(spaces: state.switchableSpaces.map(Entry.init), activeSpaceID: state.activeSpaceID)
    }

    /// More than one Space to choose between: the share extension shows its Space row.
    public var hasSpacesToChoose: Bool { spaces.count > 1 }

    public func space(_ id: UUID) -> Entry? { spaces.first { $0.id == id } }

    /// The Space a link sent without one opens in, as `BrowserState.destinationForLink` will choose it
    /// once the app has it: the Focus filter's, if listed, else the Space last used, else the first.
    public func defaultSpace(focusSpace: UUID?) -> Entry? {
        focusSpace.flatMap(space) ?? activeSpaceID.flatMap(space) ?? spaces.first
    }

    private enum CodingKeys: String, CodingKey { case version, spaces, activeSpaceID }

    /// An entry this build can't read is left out rather than failing the file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decodeIfPresent([Lossy<Entry>].self, forKey: .spaces) ?? []
        spaces = entries.compactMap(\.value)
        activeSpaceID = (try? container.decodeIfPresent(UUID.self, forKey: .activeSpaceID)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(spaces, forKey: .spaces)
        try container.encodeIfPresent(activeSpaceID, forKey: .activeSpaceID)
    }
}

/// An element that decodes as nil instead of failing the array it's in.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// `spaces-summary.json` in the app-group container. The app writes it (atomically, so a reader sees
/// the old file or the new one, never half of one); everyone else only reads it.
public struct SpacesSummaryFile: Sendable {
    public let fileURL: URL

    /// A summary bigger than this is no summary: a reader in a share extension, short of memory,
    /// doesn't load it.
    static let maximumSize = 256 * 1024

    /// Returns nil when the app group is unavailable.
    public init?(appGroup: String = AppGroup.identifier, fileManager: FileManager = .default) {
        guard let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        self.fileURL = base.appending(path: "spaces-summary.json")
    }

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// The summary, or nil when the file is missing, too big or unreadable. Never writes, moves or
    /// deletes the file.
    public func read() -> SpacesSummary? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumSize,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? CoreJSON.decoder().decode(SpacesSummary.self, from: data)
    }

    public func write(_ summary: SpacesSummary) throws {
        let data = try CoreJSON.encoder().encode(summary)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Focus filter

/// The Space a Focus filter sends links from other apps to, while a Focus with Cormorant's filter is
/// on. The system tells the app when such a Focus starts or ends (and which Space its filter names),
/// not which Focus it is. Kept in the app group's defaults, so it's there at launch and after the app
/// was killed, and the share extension can read it.
public enum FocusFilterSpace {
    static let key = "focusFilterSpaceID"

    /// The filter's Space, or nil when no Focus with the filter is on.
    public static func read(from defaults: UserDefaults) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// Records the filter's Space; nil when the Focus ends (or its filter names no Space).
    public static func write(_ spaceID: UUID?, to defaults: UserDefaults) {
        if let spaceID {
            defaults.set(spaceID.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
