import Foundation

/// A named collection of tabs, mirroring Arc's Spaces.
public struct Space: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Where a tab lives in the sidebar.
public enum TabKind: String, Hashable, Codable, Sendable {
    /// Kept until the user removes it.
    case pinned
    /// Ephemeral; eligible for automatic archiving.
    case today
}

/// A single browser tab.
public struct Tab: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var url: URL?
    public var title: String
    public var kind: TabKind
    public let createdAt: Date
    public var lastViewedAt: Date

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        title: String = "",
        kind: TabKind = .today,
        createdAt: Date = .now,
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.lastViewedAt = lastViewedAt ?? createdAt
    }
}
