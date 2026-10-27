import Foundation

/// A named collection of tabs, mirroring Arc's Spaces. Build one uses a single default Space.
public struct Space: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    /// The Space every tab lives in until Spaces ship.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static var `default`: Space { Space(id: defaultID, name: "Home") }
}

/// Where a tab lives in the sidebar.
public enum TabKind: String, Hashable, Codable, Sendable {
    /// Kept until the user removes it.
    case pinned
    /// Ephemeral; eligible for automatic archiving.
    case today

    /// Unknown raw values (written by a newer build) decode as `.today` instead of failing the whole file.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TabKind(rawValue: raw) ?? .today
    }
}

/// A single open browser tab.
public struct Tab: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    public var url: URL?
    public var title: String
    public var kind: TabKind
    /// A link opened this tab (`target=_blank`, `window.open`, Open in New Tab), so swiping back from
    /// its first page closes it.
    public var openedFromLink: Bool
    public let createdAt: Date
    public var lastViewedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID = Space.defaultID,
        url: URL? = nil,
        title: String = "",
        kind: TabKind = .today,
        openedFromLink: Bool = false,
        createdAt: Date = .now,
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.kind = kind
        self.openedFromLink = openedFromLink
        self.createdAt = createdAt
        self.lastViewedAt = lastViewedAt ?? createdAt
    }

    /// Title to show in lists: the page title, else the host, else a placeholder.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return "New Tab"
    }
}

/// A tab that was closed or auto-archived. Restorable.
public struct ArchivedTab: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    public var url: URL
    public var title: String
    public let archivedAt: Date
    public let originalCreatedAt: Date

    public init(id: UUID = UUID(), spaceID: UUID = Space.defaultID, url: URL, title: String,
                archivedAt: Date = .now, originalCreatedAt: Date) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.archivedAt = archivedAt
        self.originalCreatedAt = originalCreatedAt
    }

    /// Archive entry for `tab`, or nil for a blank (URL-less) tab, which is dropped instead of archived.
    public init?(archiving tab: Tab, at date: Date = .now) {
        guard let url = tab.url else { return nil }
        self.init(id: tab.id, spaceID: tab.spaceID, url: url, title: tab.title,
                  archivedAt: date, originalCreatedAt: tab.createdAt)
    }

    public var displayTitle: String { title.isEmpty ? (url.host() ?? url.absoluteString) : title }
}

// MARK: - Tolerant decoding
//
// Every field that a later build could add decodes with a default when missing, so an older or newer
// `browser-state.json` still loads instead of failing (and leaving the user without their tabs).
// Encoding stays synthesized.

extension Space {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        )
    }
}

extension Tab {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            spaceID: try container.decodeIfPresent(UUID.self, forKey: .spaceID) ?? Space.defaultID,
            url: try container.decodeIfPresent(URL.self, forKey: .url),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            kind: try container.decodeIfPresent(TabKind.self, forKey: .kind) ?? .today,
            openedFromLink: try container.decodeIfPresent(Bool.self, forKey: .openedFromLink) ?? false,
            createdAt: createdAt,
            lastViewedAt: try container.decodeIfPresent(Date.self, forKey: .lastViewedAt) ?? createdAt
        )
    }
}

extension ArchivedTab {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt) ?? .distantPast
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            spaceID: try container.decodeIfPresent(UUID.self, forKey: .spaceID) ?? Space.defaultID,
            url: try container.decode(URL.self, forKey: .url),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            archivedAt: archivedAt,
            originalCreatedAt: try container.decodeIfPresent(Date.self, forKey: .originalCreatedAt) ?? archivedAt
        )
    }
}
