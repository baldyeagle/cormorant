import Foundation

/// Everything the browser persists about tabs. One value, saved atomically.
public struct BrowserState: Codable, Sendable, Equatable {
    /// Version of the on-disk shape. Bump when an older build saving the file would drop data: the
    /// store keeps a copy of any file newer than this build (see `JSONBrowserStateStore.load()`).
    /// 2: profiles, and Space icon / color / profile / archive policy / archived date.
    /// 3: the archive time a Space gets back when Archive Idle Tabs is turned on (`archivePolicyBeforeOff`).
    public static let currentSchemaVersion = 3

    /// Schema version this value was decoded from (or `currentSchemaVersion` for new values), for
    /// migrations. Encoding always writes `currentSchemaVersion`.
    public var schemaVersion: Int
    /// In display order. Always holds Home (`Space.defaultID`); see `normalize()`.
    /// Change through the Space methods (`addSpace`, `updateSpace`, ...), which keep these consistent.
    public internal(set) var spaces: [Space]
    /// Always holds the default profile (`Profile.defaultID`).
    public internal(set) var profiles: [Profile]
    /// Change through the tab methods (`openTab`, `activate`, `moveTab`, ...), which keep every tab in
    /// an existing Space.
    public internal(set) var tabs: [Tab]
    public internal(set) var archived: [ArchivedTab]
    /// Never an archived Space. Change with `switchToSpace` (or `activate`, `restore`).
    public internal(set) var activeSpaceID: UUID
    /// A tab in the active Space, or nil.
    public internal(set) var activeTabID: UUID?

    /// Missing Home or default profile are added (see `normalize()`).
    public init(spaces: [Space] = [.default], profiles: [Profile] = [.default], tabs: [Tab] = [],
                archived: [ArchivedTab] = [], activeSpaceID: UUID = Space.defaultID, activeTabID: UUID? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.spaces = spaces
        self.profiles = profiles
        self.tabs = tabs
        self.archived = archived
        self.activeSpaceID = activeSpaceID
        self.activeTabID = activeTabID
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, spaces, profiles, tabs, archived, activeSpaceID, activeTabID
    }

    /// Missing fields take defaults (files from before `schemaVersion` existed are version 1), then
    /// `normalize()` repairs dangling references.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        archived = try container.decodeIfPresent([ArchivedTab].self, forKey: .archived) ?? []
        activeSpaceID = try container.decodeIfPresent(UUID.self, forKey: .activeSpaceID) ?? Space.defaultID
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        normalize()
    }

    /// Always writes `currentSchemaVersion`: the encoded shape is this build's, whatever was read.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(spaces, forKey: .spaces)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(archived, forKey: .archived)
        try container.encode(activeSpaceID, forKey: .activeSpaceID)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
    }

    public static let empty = BrowserState()

    /// Tabs in the active Space, most recently viewed first.
    public var activeSpaceTabs: [Tab] { tabs(inSpace: activeSpaceID) }

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
    /// so the next `save` starts a fresh file without destroying the old one. A file from a newer
    /// build (higher `schemaVersion`) loads, but is first copied to `<name>.v<version>-<timestamp>.json`,
    /// since saving it in this build's shape drops what this build doesn't know.
    public func load() async throws -> BrowserState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        }
        let state: BrowserState
        do {
            state = try CoreJSON.decoder().decode(BrowserState.self, from: data)
        } catch {
            throw BrowserStateStoreError.unreadable(quarantinedTo: quarantine(), underlying: "\(error)")
        }
        if state.schemaVersion > BrowserState.currentSchemaVersion {
            try keepNewerCopy(version: state.schemaVersion)
        }
        return state
    }

    /// Copies a newer build's file aside, once per version. If that fails, the file is quarantined
    /// instead (`unreadable`), so nothing saves over the only copy.
    private func keepNewerCopy(version: Int) throws {
        let prefix = "\(fileURL.deletingPathExtension().lastPathComponent).v\(version)-"
        let directory = fileURL.deletingLastPathComponent()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        guard !existing.contains(where: { $0.hasPrefix(prefix) }) else { return }
        do {
            try FileManager.default.copyItem(at: fileURL, to: sideFile(tag: "v\(version)"))
        } catch {
            throw BrowserStateStoreError.unreadable(quarantinedTo: quarantine(),
                                                    underlying: "couldn't keep a copy of a v\(version) file: \(error)")
        }
    }

    /// Moves the unreadable file next to itself under a timestamped name. Best effort: nil on failure.
    private func quarantine() -> URL? {
        let destination = sideFile(tag: "corrupt")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// An unused path next to the file: `<name>.<tag>-<timestamp>.json`.
    private func sideFile(tag: String, now: Date = .now) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        // Basic ISO 8601 (no `:`), e.g. 20261022T070701.123Z, so the name is safe everywhere.
        let stamp = now.formatted(.iso8601
            .year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: true).timeSeparator(.omitted))
        let destination = directory.appending(path: "\(base).\(tag)-\(stamp).\(ext)")
        guard FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { return destination }
        return directory.appending(path: "\(base).\(tag)-\(stamp)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    public func save(_ state: BrowserState) async throws {
        let data = try CoreJSON.encoder().encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Decides which tabs are due for archiving.
public struct ArchivePolicy: Sendable, Hashable, Codable {
    /// Idle time before a tab is archived. `nil` disables auto-archive.
    public var interval: TimeInterval?

    public init(interval: TimeInterval? = 24 * 60 * 60) {
        self.interval = interval
    }

    public static let twelveHours = ArchivePolicy(interval: 12 * 60 * 60)
    public static let oneDay = ArchivePolicy(interval: 24 * 60 * 60)
    public static let off = ArchivePolicy(interval: nil)

    private enum CodingKeys: String, CodingKey { case interval }

    /// Off is written as `"interval": null`, so a shape this build doesn't know (no `interval` key)
    /// reads as 24 hours rather than off. A time that isn't positive, or is longer than a century, is
    /// unreadable (the archiver would take every tab at once, or the label couldn't show it): the Space
    /// decoder then falls back to 24 hours.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.interval) else { self = .oneDay; return }
        interval = try container.decodeNil(forKey: .interval) ? nil : container.decode(TimeInterval.self, forKey: .interval)
        if let interval, !(interval > 0 && interval <= Self.longest) {
            throw DecodingError.dataCorruptedError(forKey: .interval, in: container,
                                                   debugDescription: "archive interval \(interval) out of range")
        }
    }

    /// The longest time a file may hold: a century.
    static let longest: TimeInterval = 100 * 365 * 24 * 60 * 60

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interval, forKey: .interval)
    }

    /// Tabs idle at least `interval`, excluding `activeTabID` and any tab whose `kind` keeps it open.
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

    /// Adds a Today tab and makes it active, or leaves the active tab alone when `activate` is false
    /// (a background tab). `fromLink` marks a tab a link opened.
    ///
    /// The tab goes in `spaceID` (a tab opened by another tab's page belongs with its opener, whatever
    /// Space is showing), or the active Space when that's nil, unknown or archived. A tab opened outside
    /// the active Space never becomes active.
    public mutating func openTab(url: URL?, title: String = "", inSpace spaceID: UUID? = nil,
                                 activate: Bool = true, fromLink: Bool = false, now: Date = .now) -> Tab {
        var target = activeSpaceID
        if let spaceID, space(spaceID)?.isArchived == false { target = spaceID }
        let tab = Tab(spaceID: target, url: url, title: title, kind: .today,
                      openedFromLink: fromLink, createdAt: now)
        tabs.append(tab)
        if activate, target == activeSpaceID { activeTabID = tab.id }
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

    /// Archives every tab its Space's `archivePolicy` says is due. Archived Spaces keep their tabs.
    @discardableResult
    public mutating func runArchive(now: Date = .now) -> [ArchivedTab] {
        let due = switchableSpaces.flatMap { space in
            space.archivePolicy.tabsDue(in: tabs.filter { $0.spaceID == space.id }, activeTabID: activeTabID, now: now)
        }
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
    /// The tab returns to its original Space if that Space still exists and isn't archived (switching
    /// to it), otherwise it opens in the active Space.
    @discardableResult
    public mutating func restore(archivedID: UUID, now: Date = .now) -> Tab? {
        guard let index = archived.firstIndex(where: { $0.id == archivedID }) else { return nil }
        let entry = archived.remove(at: index)
        let spaceID = space(entry.spaceID)?.isArchived == false ? entry.spaceID : activeSpaceID
        let tab = Tab(spaceID: spaceID, url: entry.url, title: entry.title, kind: .today, createdAt: now)
        tabs.append(tab)
        if spaceID != activeSpaceID, let activeTabID { markViewed(tabID: activeTabID, now: now) }
        activeSpaceID = spaceID
        activeTabID = tab.id
        return tab
    }

    /// Marks a tab as viewed now and active. Switches to the tab's Space, restoring it first if it was
    /// archived (the user chose one of its tabs). No-op for unknown IDs.
    public mutating func activate(tabID: UUID, now: Date = .now) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        restoreSpace(tabs[index].spaceID, now: now)
        if tabs[index].spaceID != activeSpaceID, let activeTabID { markViewed(tabID: activeTabID, now: now) }
        tabs[index].lastViewedAt = now
        activeSpaceID = tabs[index].spaceID
        activeTabID = tabID
    }

    /// Counts the tab as viewed at `now` without changing which tab is active (so it doesn't auto-archive
    /// as if idle since it was last activated). No-op for unknown IDs.
    public mutating func markViewed(tabID: UUID, now: Date = .now) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].lastViewedAt = now
    }

    /// Drops every URL-less tab, clearing the active tab if it was one.
    public mutating func removeBlankTabs() {
        tabs.removeAll { $0.url == nil }
        if let activeTabID, !tabs.contains(where: { $0.id == activeTabID }) { self.activeTabID = nil }
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

    public mutating func deleteArchived(_ archivedID: UUID) { archived.removeAll { $0.id == archivedID } }

    public mutating func clearArchive() { archived.removeAll() }
}

public enum AppGroup {
    public static let identifier = "group.dev.baldyeagle.cormorant"
}
