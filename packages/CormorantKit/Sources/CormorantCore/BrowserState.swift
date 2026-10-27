import Foundation

/// Everything the browser persists about tabs. One value, saved atomically.
public struct BrowserState: Codable, Sendable, Equatable {
    /// Version of the on-disk shape. Bump when a change needs a migration rather than a decode default.
    public static let currentSchemaVersion = 1

    /// Schema version this value was decoded from (or `currentSchemaVersion` for new values), for
    /// migrations. Encoding always writes `currentSchemaVersion`.
    public var schemaVersion: Int
    public var spaces: [Space]
    public var tabs: [Tab]
    public var archived: [ArchivedTab]
    public var activeSpaceID: UUID
    public var activeTabID: UUID?

    public init(spaces: [Space] = [.default], tabs: [Tab] = [], archived: [ArchivedTab] = [],
                activeSpaceID: UUID = Space.defaultID, activeTabID: UUID? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.spaces = spaces
        self.tabs = tabs
        self.archived = archived
        self.activeSpaceID = activeSpaceID
        self.activeTabID = activeTabID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, spaces, tabs, archived, activeSpaceID, activeTabID
    }

    /// Missing fields take defaults (files from before `schemaVersion` existed are version 1).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        self.spaces = spaces.isEmpty ? [.default] : spaces
        tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        archived = try container.decodeIfPresent([ArchivedTab].self, forKey: .archived) ?? []
        activeSpaceID = try container.decodeIfPresent(UUID.self, forKey: .activeSpaceID) ?? Space.defaultID
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
    }

    /// Always writes `currentSchemaVersion`: the encoded shape is this build's, whatever was read.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(spaces, forKey: .spaces)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(archived, forKey: .archived)
        try container.encode(activeSpaceID, forKey: .activeSpaceID)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
    }

    public static let empty = BrowserState()

    /// Tabs in the active Space, most recently viewed first.
    public var activeSpaceTabs: [Tab] {
        tabs.filter { $0.spaceID == activeSpaceID }.sorted { $0.lastViewedAt > $1.lastViewedAt }
    }

    /// Archived tabs grouped by calendar day of archiving, newest day first.
    public func archivedByDay(calendar: Calendar = .current) -> [(day: Date, tabs: [ArchivedTab])] {
        let groups = Dictionary(grouping: archived) { calendar.startOfDay(for: $0.archivedAt) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.archivedAt > $1.archivedAt })
        }
    }
}

/// Thrown by `BrowserStateStore.load()` when a file exists but cannot be decoded. The store moves
/// the unreadable file aside first so a later save cannot overwrite it; `quarantinedTo` is where it went.
public enum BrowserStateStoreError: Error, Sendable {
    case unreadable(quarantinedTo: URL?, underlying: String)
}

/// Persists `BrowserState`. Implementations must be safe to call from any task.
/// `load()` throws `BrowserStateStoreError.unreadable` for a corrupt or incompatible file; callers must
/// NOT fall back to `.empty` and then save, since that destroys the user's data.
public protocol BrowserStateStore: Sendable {
    func load() async throws -> BrowserState
    func save(_ state: BrowserState) async throws
}

/// JSON file store. Writes atomically; a missing file loads as `.empty`; an undecodable file is
/// quarantined (see `load()`).
public actor JSONBrowserStateStore: BrowserStateStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Store inside the app-group container so a share extension can read the same state later.
    /// Returns nil when the app group is unavailable (misconfigured entitlement) rather than silently
    /// using a different directory.
    public init?(appGroup: String = AppGroup.identifier, fileManager: FileManager = .default) {
        guard let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        self.fileURL = base.appending(path: "browser-state.json")
    }

    /// Loads the saved state. A missing file is `.empty`. Read errors other than "no such file" (for
    /// example data protection before first unlock) propagate unchanged and leave the file alone.
    /// A file that exists but does not decode is moved aside to
    /// `<name>.corrupt-<ISO 8601 timestamp>.json` and `BrowserStateStoreError.unreadable` is thrown,
    /// so the next `save` starts a fresh file without destroying the old one.
    public func load() async throws -> BrowserState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        }
        do {
            return try CoreJSON.decoder().decode(BrowserState.self, from: data)
        } catch {
            throw BrowserStateStoreError.unreadable(quarantinedTo: quarantine(), underlying: "\(error)")
        }
    }

    /// Moves the unreadable file next to itself under a timestamped name. Best effort: nil on failure.
    private func quarantine(now: Date = .now) -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        // Basic ISO 8601 (no `:`), e.g. 20261022T070701.123Z, so the name is safe everywhere.
        let stamp = now.formatted(.iso8601
            .year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: true).timeSeparator(.omitted))
        var destination = directory.appending(path: "\(base).corrupt-\(stamp).\(ext)")
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = directory.appending(path: "\(base).corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    public func save(_ state: BrowserState) async throws {
        let data = try CoreJSON.encoder().encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Decides which Today tabs are due for archiving.
public struct ArchivePolicy: Sendable, Equatable, Codable {
    /// Idle time before a Today tab is archived. `nil` disables auto-archive.
    public var interval: TimeInterval?

    public init(interval: TimeInterval? = 24 * 60 * 60) {
        self.interval = interval
    }

    public static let twelveHours = ArchivePolicy(interval: 12 * 60 * 60)
    public static let oneDay = ArchivePolicy(interval: 24 * 60 * 60)
    public static let off = ArchivePolicy(interval: nil)

    /// Today tabs idle longer than `interval`, excluding `activeTabID`. Pinned tabs never archive.
    ///
    /// Blank (URL-less) tabs are returned too, so the archiver drops them.
    public func tabsDue(in tabs: [Tab], activeTabID: UUID?, now: Date = .now) -> [Tab] {
        guard let interval else { return [] }
        return tabs.filter { tab in
            tab.kind == .today
                && tab.id != activeTabID
                && now.timeIntervalSince(tab.lastViewedAt) >= interval
        }
    }
}

/// Mutations on `BrowserState` that the UI and the archiver both use.
extension BrowserState {
    /// Maximum number of archived entries kept; the oldest are dropped beyond this.
    public static let archiveCapacity = 2_000

    /// Adds a Today tab in the active Space and makes it active, or leaves the active tab alone when
    /// `activate` is false (a background tab). `fromLink` marks a tab a link opened.
    public mutating func openTab(url: URL?, title: String = "", activate: Bool = true,
                                 fromLink: Bool = false, now: Date = .now) -> Tab {
        let tab = Tab(spaceID: activeSpaceID, url: url, title: title, kind: .today,
                      openedFromLink: fromLink, createdAt: now)
        tabs.append(tab)
        if activate { activeTabID = tab.id }
        return tab
    }

    /// The tab archiving this one makes active if it's active: the most recently viewed other tab in
    /// its Space. Nil for an unknown tab or when nothing else is open there.
    public func tabAfterArchiving(_ tabID: UUID) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        return tabs
            .filter { $0.spaceID == tab.spaceID && $0.id != tabID }
            .max { $0.lastViewedAt < $1.lastViewedAt }?
            .id
    }

    /// Moves the tab to the archive (or drops it if it has no URL) and picks a new active tab.
    ///
    /// If the archived tab was active, `tabAfterArchiving(_:)` becomes active (or nil if there is
    /// none). Archiving a background tab leaves the active tab alone.
    public mutating func archive(tabID: UUID, now: Date = .now) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if activeTabID == tabID { activeTabID = tabAfterArchiving(tabID) }
        let tab = tabs.remove(at: index)
        if let entry = ArchivedTab(archiving: tab, at: now) {
            archived.append(entry)
            trimArchive()
        }
    }

    /// Archives every tab the policy says is due.
    @discardableResult
    public mutating func runArchive(policy: ArchivePolicy, now: Date = .now) -> [ArchivedTab] {
        let due = policy.tabsDue(in: tabs, activeTabID: activeTabID, now: now)
        guard !due.isEmpty else { return [] }
        var result: [ArchivedTab] = []
        for tab in due {
            if let entry = ArchivedTab(archiving: tab, at: now) { result.append(entry) }
            archive(tabID: tab.id, now: now)
        }
        return result
    }

    /// Reopens an archived tab as a Today tab and makes it active.
    ///
    /// The tab returns to its original Space if that Space still exists (switching to it),
    /// otherwise it opens in the active Space.
    @discardableResult
    public mutating func restore(archivedID: UUID, now: Date = .now) -> Tab? {
        guard let index = archived.firstIndex(where: { $0.id == archivedID }) else { return nil }
        let entry = archived.remove(at: index)
        let spaceID = spaces.contains { $0.id == entry.spaceID } ? entry.spaceID : activeSpaceID
        let tab = Tab(spaceID: spaceID, url: entry.url, title: entry.title, kind: .today, createdAt: now)
        tabs.append(tab)
        activeSpaceID = spaceID
        activeTabID = tab.id
        return tab
    }

    /// Marks a tab as viewed now and active. Switches to the tab's Space. No-op for unknown IDs.
    public mutating func activate(tabID: UUID, now: Date = .now) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].lastViewedAt = now
        activeSpaceID = tabs[index].spaceID
        activeTabID = tabID
    }

    /// Sets whichever of `url` and `title` is non-nil. No-op for unknown IDs.
    public mutating func update(tabID: UUID, url: URL?, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if let url { tabs[index].url = url }
        if let title { tabs[index].title = title }
    }

    /// Drops the oldest archived entries beyond `archiveCapacity`, preserving the order of the rest.
    mutating func trimArchive() {
        let overflow = archived.count - Self.archiveCapacity
        guard overflow > 0 else { return }
        let dropped = Set(
            archived.indices
                .sorted { archived[$0].archivedAt < archived[$1].archivedAt }
                .prefix(overflow)
        )
        archived = archived.indices.filter { !dropped.contains($0) }.map { archived[$0] }
    }

    public mutating func clearArchive() { archived.removeAll() }
}

public enum AppGroup {
    public static let identifier = "group.dev.baldyeagle.cormorant"
}
