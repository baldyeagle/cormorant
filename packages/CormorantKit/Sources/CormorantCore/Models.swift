import Foundation

/// A named collection of tabs, mirroring Arc's Spaces. Each Space uses one `Profile` (its logins and
/// website data); several Spaces can share one.
public struct Space: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var icon: SpaceIcon
    public var color: Swatch
    public var profileID: UUID
    /// Idle time before this Space's tabs archive.
    public var archivePolicy: ArchivePolicy
    /// The policy Settings' Archive Idle Tabs switch turned off, which turning it back on restores
    /// (`stopArchivingIdleTabs` / `resumeArchivingIdleTabs`). Nil unless that switch turned it off.
    public var archivePolicyBeforeOff: ArchivePolicy?
    /// Set while the Space is archived: kept with its tabs, but out of switching.
    public var archivedAt: Date?
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, icon: SpaceIcon = .house, color: Swatch = .teal,
                profileID: UUID = Profile.defaultID, archivePolicy: ArchivePolicy = .oneDay,
                archivePolicyBeforeOff: ArchivePolicy? = nil, archivedAt: Date? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.profileID = profileID
        self.archivePolicy = archivePolicy
        self.archivePolicyBeforeOff = archivePolicyBeforeOff
        self.archivedAt = archivedAt
        self.createdAt = createdAt
    }

    public var isArchived: Bool { archivedAt != nil }

    /// Home: always exists, can be renamed but not archived or deleted.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static var `default`: Space { Space(id: defaultID, name: "Home", createdAt: .distantPast) }
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
            icon: try container.decodeIfPresent(SpaceIcon.self, forKey: .icon) ?? .house,
            color: try container.decodeIfPresent(Swatch.self, forKey: .color) ?? .teal,
            profileID: try container.decodeIfPresent(UUID.self, forKey: .profileID) ?? Profile.defaultID,
            // A policy this build can't read (a newer build's shape) costs the setting, not the file.
            archivePolicy: (try? container.decodeIfPresent(ArchivePolicy.self, forKey: .archivePolicy)) ?? .oneDay,
            archivePolicyBeforeOff: (try? container.decodeIfPresent(ArchivePolicy.self, forKey: .archivePolicyBeforeOff)),
            archivedAt: try container.decodeIfPresent(Date.self, forKey: .archivedAt),
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
