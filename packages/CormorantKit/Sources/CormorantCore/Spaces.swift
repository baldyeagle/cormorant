import Foundation

/// Logins, cookies and website data, shared by the Spaces that use it. The default profile is the
/// app's existing default website data store, so nobody is signed out when Spaces arrive; every
/// other profile gets its own store, identified by the profile's `id`.
public struct Profile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var color: Swatch
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, color: Swatch = .blue, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// The profile backed by the default website data store. Always exists; can be renamed, not deleted.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static var `default`: Profile { Profile(id: defaultID, name: "Default", createdAt: .distantPast) }

    /// The letter shown in the profile's monogram: the first letter of its name, or "?" for a blank name.
    public var monogram: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }
}

extension Profile {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            color: try container.decodeIfPresent(Swatch.self, forKey: .color) ?? .blue,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        )
    }
}

/// The colors a Space or profile can take. The app maps each to its sRGB value via `rgb`.
public enum Swatch: String, CaseIterable, Hashable, Codable, Sendable {
    case teal, indigo, orange, green, pink, blue, gold, gray

    public var rgb: RGBColor {
        switch self {
        case .teal: RGBColor(hex: 0x0A9BA8)
        case .indigo: RGBColor(hex: 0x5E5CE6)
        case .orange: RGBColor(hex: 0xF2711C)
        case .green: RGBColor(hex: 0x2FB350)
        case .pink: RGBColor(hex: 0xE8437A)
        case .blue: RGBColor(hex: 0x0088FF)
        case .gold: RGBColor(hex: 0xB38600)
        case .gray: RGBColor(hex: 0x8E8E93)
        }
    }

    /// Unknown values (written by a newer build, even of another type) decode as `.teal` instead of
    /// failing the whole file.
    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Swatch.init(rawValue:)) ?? .teal
    }
}

/// The icons a Space can take. Raw values are SF Symbol names.
public enum SpaceIcon: String, CaseIterable, Hashable, Codable, Sendable {
    case house
    case briefcase
    case hammer
    case airplane
    case book
    case cart
    case heart
    case leaf
    case gameController = "gamecontroller"
    case musicNote = "music.note"
    case graduationCap = "graduationcap"
    case camera

    /// Unknown values (written by a newer build, even of another type) decode as `.house` instead of
    /// failing the whole file.
    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(SpaceIcon.init(rawValue:)) ?? .house
    }
}

// MARK: - Spaces and profiles on BrowserState

extension BrowserState {
    /// Spaces you can switch to, in order.
    public var switchableSpaces: [Space] { spaces.filter { !$0.isArchived } }

    /// Archived Spaces, most recently archived first.
    public var archivedSpaces: [Space] {
        spaces.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// More than one Space to switch between. With only Home, Spaces stay out of sight.
    public var hasSpacesToSwitch: Bool { switchableSpaces.count > 1 }

    public var activeSpace: Space { space(activeSpaceID) ?? .default }

    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    public func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    /// The profile `spaceID` uses; the default profile for an unknown Space.
    public func profile(forSpace spaceID: UUID) -> Profile {
        space(spaceID).flatMap { profile($0.profileID) } ?? .default
    }

    /// Tabs in `spaceID`, most recently viewed first.
    public func tabs(inSpace spaceID: UUID) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID }.sorted { $0.lastViewedAt > $1.lastViewedAt }
    }

    /// How many tabs are open in `spaceID`.
    public func tabCount(inSpace spaceID: UUID) -> Int {
        tabs.count { $0.spaceID == spaceID }
    }

    /// Spaces that use `profileID`, in order.
    public func spaces(usingProfile profileID: UUID) -> [Space] {
        spaces.filter { $0.profileID == profileID }
    }

    /// Repairs references so the state always has somewhere to put a tab: Space and profile IDs are
    /// unique, Home and the default profile exist, Home isn't archived, every Space's profile exists,
    /// every open tab belongs to an existing Space, the active Space is a switchable one, and the active
    /// tab is in it. Archived tabs keep their Space ID even if it's gone (`restore` handles that).
    /// `init`, decoding, `updateSpace` and `deleteProfile` call it; the other mutations keep these
    /// invariants themselves. Doesn't count any tab as viewed.
    public mutating func normalize() {
        var seenSpaces = Set<UUID>(), seenProfiles = Set<UUID>()
        spaces.removeAll { !seenSpaces.insert($0.id).inserted }
        profiles.removeAll { !seenProfiles.insert($0.id).inserted }
        if !profiles.contains(where: \.isDefault) { profiles.insert(.default, at: 0) }
        if let home = spaces.firstIndex(where: { $0.id == Space.defaultID }) {
            spaces[home].archivedAt = nil
        } else {
            spaces.insert(.default, at: 0)
        }
        let profileIDs = Set(profiles.map(\.id))
        for index in spaces.indices where !profileIDs.contains(spaces[index].profileID) {
            spaces[index].profileID = Profile.defaultID
        }
        let spaceIDs = Set(spaces.map(\.id))
        for index in tabs.indices where !spaceIDs.contains(tabs[index].spaceID) {
            tabs[index].spaceID = Space.defaultID
        }
        if let activeTabID, !tabs.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = nil
        }
        let leavesSpace = space(activeSpaceID)?.isArchived != false
        if leavesSpace { activeSpaceID = Space.defaultID }
        // A tab outside the active Space gives way to the Space's most recent one; so does none, when
        // the Space itself was replaced.
        let activeTabSpace = activeTabID.flatMap { id in tabs.first { $0.id == id }?.spaceID }
        if activeTabSpace != activeSpaceID, leavesSpace || activeTabID != nil {
            activeTabID = tabs(inSpace: activeSpaceID).first?.id
        }
    }

    /// Makes `spaceID` active, along with its most recently viewed tab (nil when it has none). Both the
    /// tab being left and the one arrived at count as viewed at `now`, so returning to a Space finds the
    /// tab you left there. No-op for an unknown or archived Space, or the active one.
    public mutating func switchToSpace(_ spaceID: UUID, now: Date = .now) {
        guard spaceID != activeSpaceID, let space = space(spaceID), !space.isArchived else { return }
        if let activeTabID { markViewed(tabID: activeTabID, now: now) }
        activeSpaceID = spaceID
        activeTabID = tabs(inSpace: spaceID).first?.id
        if let activeTabID { markViewed(tabID: activeTabID, now: now) }
    }

    /// Adds a Space at the end of the list. Does not switch to it. An unknown `profileID` falls back to
    /// the default profile. While no Space archives idle tabs (`archivesIdleTabs`), the new one doesn't
    /// either, until `resumeArchivingIdleTabs` gives it 24 hours.
    @discardableResult
    public mutating func addSpace(name: String, icon: SpaceIcon = .house, color: Swatch = .teal,
                                  profileID: UUID = Profile.defaultID, now: Date = .now) -> Space {
        var space = Space(name: name, icon: icon, color: color,
                          profileID: profile(profileID) == nil ? Profile.defaultID : profileID, createdAt: now)
        // With Archive Idle Tabs off, a new Space is off too, and gets the default when it's turned back on.
        if !archivesIdleTabs {
            space.archivePolicy = .off
            space.archivePolicyBeforeOff = .oneDay
        }
        spaces.append(space)
        return space
    }

    /// Moves the Space to just before `otherID` in the list, or to the end when that's nil or unknown.
    /// No-op for an unknown Space or `otherID == spaceID`.
    public mutating func moveSpace(_ spaceID: UUID, before otherID: UUID?) {
        guard spaceID != otherID, let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let space = spaces.remove(at: index)
        let destination = otherID.flatMap { id in spaces.firstIndex { $0.id == id } } ?? spaces.endIndex
        spaces.insert(space, at: destination)
    }

    /// Applies `change` to the Space. `id` can't change; an unknown profile falls back to the default.
    /// `archivedAt` can't change here either: use `archiveSpace` / `restoreSpace`. A new archive policy
    /// replaces any remembered by `stopArchivingIdleTabs`, and keeps Settings' Archive Idle Tabs
    /// switch (`archivesIdleTabs`) honest: a time picked while it's off turns it on for this Space
    /// alone, forgetting every other Space's remembered time (which would otherwise come back on its
    /// own later); turning off the last Space with a time turns the switch off, remembering that
    /// time as the switch would. No-op for an unknown Space.
    ///
    /// Returns whether the Space's profile changed, in which case its tabs must reload in the new
    /// profile's data store.
    @discardableResult
    public mutating func updateSpace(_ spaceID: UUID, _ change: (inout Space) -> Void) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return false }
        let before = profile(forSpace: spaceID).id
        let archivedAt = spaces[index].archivedAt, policy = spaces[index].archivePolicy
        let wasArchiving = archivesIdleTabs
        change(&spaces[index])
        spaces[index].archivedAt = archivedAt
        if spaces[index].archivePolicy != policy {
            spaces[index].archivePolicyBeforeOff = nil
            if !wasArchiving, archivesIdleTabs {
                for other in spaces.indices { spaces[other].archivePolicyBeforeOff = nil }
            } else if wasArchiving, !archivesIdleTabs, policy.interval != nil {
                spaces[index].archivePolicyBeforeOff = policy
            }
        }
        normalize()
        return profile(forSpace: spaceID).id != before
    }

    /// Archives the Space with its tabs (they're kept, and don't auto-archive meanwhile). If it was
    /// active, switches to Home. Home can't be archived. Returns whether the Space was archived.
    @discardableResult
    public mutating func archiveSpace(_ spaceID: UUID, now: Date = .now) -> Bool {
        guard spaceID != Space.defaultID,
              let index = spaces.firstIndex(where: { $0.id == spaceID }),
              !spaces[index].isArchived else { return false }
        if activeSpaceID == spaceID { switchToSpace(Space.defaultID, now: now) }
        spaces[index].archivedAt = now
        return true
    }

    /// Brings an archived Space back into switching, at its old place in the list. Does not switch to it.
    /// Its tabs' idle time stops at archiving: each moves forward by the time the Space was away, so
    /// they keep their order and don't come back already due for auto-archive. Returns whether the
    /// Space was archived.
    @discardableResult
    public mutating func restoreSpace(_ spaceID: UUID, now: Date = .now) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
              let archivedAt = spaces[index].archivedAt else { return false }
        let away = max(0, now.timeIntervalSince(archivedAt))
        for tab in tabs.indices where tabs[tab].spaceID == spaceID {
            tabs[tab].lastViewedAt = min(tabs[tab].lastViewedAt + away, now)
        }
        spaces[index].archivedAt = nil
        return true
    }

    /// Deletes the Space. Its tabs go to the tab archive (blank tabs are dropped), where they keep the
    /// deleted Space's ID and restore into the active Space. If it was active, switches to Home. Home
    /// can't be deleted. Returns whether the Space was deleted.
    @discardableResult
    public mutating func deleteSpace(_ spaceID: UUID, now: Date = .now) -> Bool {
        guard spaceID != Space.defaultID, let index = spaces.firstIndex(where: { $0.id == spaceID }) else {
            return false
        }
        let doomed = tabs.filter { $0.spaceID == spaceID }
        tabs.removeAll { $0.spaceID == spaceID }
        archived.append(contentsOf: doomed.compactMap { ArchivedTab(archiving: $0, at: now) })
        trimArchive()
        spaces.remove(at: index)
        if activeSpaceID == spaceID { switchToSpace(Space.defaultID, now: now) }
        return true
    }

    /// Moves a tab to another Space, keeping its kind and history, and counts the move as a view (so it
    /// doesn't arrive already due for the destination's archive policy). If it was the active tab, the
    /// most recently viewed tab left in its old Space becomes active (or none); moved into an active
    /// Space with no active tab, it becomes active. No-op for an unknown
    /// tab, an unknown or archived Space, or a tab already there.
    ///
    /// Returns whether the destination uses a different profile, in which case the page must reload in
    /// that profile's data store (its cookies stay behind). Nil when nothing moved.
    @discardableResult
    public mutating func moveTab(_ tabID: UUID, toSpace spaceID: UUID, now: Date = .now) -> Bool? {
        guard space(spaceID)?.isArchived == false,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].spaceID != spaceID else { return nil }
        let from = tabs[index].spaceID
        if activeTabID == tabID { activeTabID = tabAfterArchiving(tabID) }
        tabs[index].spaceID = spaceID
        tabs[index].lastViewedAt = now
        if spaceID == activeSpaceID, activeTabID == nil { activeTabID = tabID }
        return profile(forSpace: from).id != profile(forSpace: spaceID).id
    }

    /// Adds a profile. Spaces start using it only when assigned.
    @discardableResult
    public mutating func addProfile(name: String, color: Swatch = .blue, now: Date = .now) -> Profile {
        let profile = Profile(name: name, color: color, createdAt: now)
        profiles.append(profile)
        return profile
    }

    /// Applies `change` to the profile (`id` can't change). No-op for an unknown profile.
    public mutating func updateProfile(_ profileID: UUID, _ change: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        change(&profiles[index])
    }

    /// Deletes the profile; the Spaces that used it switch to the default profile. Returns those Spaces'
    /// IDs, whose tabs must reload, or nil if nothing was deleted (unknown or default profile). Erasing
    /// the profile's website data store is the caller's job.
    @discardableResult
    public mutating func deleteProfile(_ profileID: UUID) -> [UUID]? {
        guard profileID != Profile.defaultID, let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return nil
        }
        let affected = spaces(usingProfile: profileID).map(\.id)
        profiles.remove(at: index)
        normalize()
        return affected
    }
}
