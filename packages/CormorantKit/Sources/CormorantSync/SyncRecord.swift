import CormorantCore
import Foundation

/// Names a synced record: a Space, a profile, an open tab, a folder, an archived tab, or one of the two lists
/// that keep order. Only ever sent encrypted (`SyncCipher`).
public struct SyncRecordID: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, CaseIterable {
        case space, profile, folder, tab, archived, order
    }

    /// `<kind>.<UUID>`, or `order.spaces` / `order.tabs`.
    public let name: String

    public init?(name: String) {
        guard let dot = name.firstIndex(of: "."), Kind(rawValue: String(name[..<dot])) != nil,
              name.index(after: dot) != name.endIndex else { return nil }
        self.name = name
    }

    private init(_ kind: Kind, _ rest: String) { name = "\(kind.rawValue).\(rest)" }

    public static func space(_ id: UUID) -> SyncRecordID { SyncRecordID(.space, id.uuidString) }
    public static func profile(_ id: UUID) -> SyncRecordID { SyncRecordID(.profile, id.uuidString) }
    public static func folder(_ id: UUID) -> SyncRecordID { SyncRecordID(.folder, id.uuidString) }
    public static func tab(_ id: UUID) -> SyncRecordID { SyncRecordID(.tab, id.uuidString) }
    public static func archived(_ id: UUID) -> SyncRecordID { SyncRecordID(.archived, id.uuidString) }
    /// The Spaces' order: `ids` is every Space's ID.
    public static let spaceOrder = SyncRecordID(.order, "spaces")
    /// The open tabs' order (`BrowserState.tabs`): pins' order in their Space, and a list's.
    public static let tabOrder = SyncRecordID(.order, "tabs")

    public var kind: Kind { Kind(rawValue: String(name.prefix { $0 != "." }))! }
    public var description: String { name }

    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let id = SyncRecordID(name: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a record ID: \(name)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// A synced record's fields: the JSON of a `Space`, `Profile`, `Tab`, `Folder` or `ArchivedTab`, or `ids` for
/// an order list.
public struct SyncRecord: Hashable, Sendable, Codable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) { self.fields = fields }

    static let idsField = "ids"

    init(ids: [UUID]) { fields = [Self.idsField: .array(ids.map { .string($0.uuidString) })] }

    /// An order list's IDs; entries that aren't UUIDs are skipped.
    var ids: [UUID] {
        guard case .array(let values) = fields[Self.idsField] else { return [] }
        return values.compactMap { if case .string(let text) = $0 { UUID(uuidString: text) } else { nil } }
    }
}

extension SyncRecord {
    /// Whether this build can make its model of the record. Lists have none: always.
    func reads(as id: SyncRecordID) -> Bool {
        switch id.kind {
        case .space: SyncJSON.decode(Space.self, from: fields) != nil
        case .profile: SyncJSON.decode(Profile.self, from: fields) != nil
        case .tab: SyncJSON.decode(Tab.self, from: fields) != nil
        case .archived: SyncJSON.decode(ArchivedTab.self, from: fields) != nil
        case .folder: SyncJSON.decode(Folder.self, from: fields) != nil
        case .order: true
        }
    }

    /// The records this one points at, which have to be here before it's shown: a tab's Space and
    /// folder, a Space's profile, a folder's Space. Without them the state would repair the reference
    /// (a tab moved to Home, say), and the repair would be sent back as if it were a change.
    func requirements(id: SyncRecordID) -> [SyncRecordID] {
        func reference(_ field: String, _ make: (UUID) -> SyncRecordID) -> SyncRecordID? {
            guard case .string(let text) = fields[field], let uuid = UUID(uuidString: text) else { return nil }
            return make(uuid)
        }
        return switch id.kind {
        case .tab: [reference("spaceID", SyncRecordID.space), reference("folderID", SyncRecordID.folder)].compactMap { $0 }
        case .space: [reference("profileID", SyncRecordID.profile)].compactMap { $0 }
        case .folder: [reference("spaceID", SyncRecordID.space)].compactMap { $0 }
        case .profile, .archived, .order: []
        }
    }
}

/// Every record, by ID.
public typealias SyncSnapshot = [SyncRecordID: SyncRecord]

extension SyncSnapshot {
    /// The records of `shared`. `keeping` is the last known cloud copy of them: where this build reads
    /// a cloud field and writes it back differently (a field or a value a newer build added), and the
    /// field hasn't changed here, the cloud's value is kept, so saving a record never drops it.
    public init(_ shared: BrowserState.Shared, keeping known: SyncSnapshot = [:]) {
        self.init()
        func add<Model: Codable & Hashable & Sendable>(_ id: SyncRecordID, _ value: Model) {
            guard var fields = SyncJSON.fields(of: value) else { return }
            if let cloud = known[id]?.fields, cloud != fields,
               let model = SyncJSON.decode(Model.self, from: cloud), let asRead = SyncJSON.fields(of: model) {
                // A kind of tab this build doesn't know: what it would clear for not being a pin stays too.
                let unknownKind = cloud["kind"] != asRead["kind"]
                for (key, value) in cloud where fields[key] == asRead[key] || (unknownKind && fields[key] == nil) {
                    fields[key] = value
                }
            }
            self[id] = SyncRecord(fields: fields)
        }
        for space in shared.spaces { add(.space(space.id), space) }
        for profile in shared.profiles { add(.profile(profile.id), profile) }
        for tab in shared.tabs where BrowserState.isShared(tab) { add(.tab(tab.id), tab) }
        for folder in shared.folders { add(.folder(folder.id), folder) }
        for tab in shared.archived { add(.archived(tab.id), tab) }
        self[.spaceOrder] = SyncRecord(ids: shared.spaces.map(\.id))
        self[.tabOrder] = SyncRecord(ids: shared.tabs.filter(BrowserState.isShared).map(\.id))
    }

    /// The IDs `init(_:)` gives `shared`'s records, without building them.
    static func ids(of shared: BrowserState.Shared) -> Set<SyncRecordID> {
        var ids: Set<SyncRecordID> = [.spaceOrder, .tabOrder]
        ids.formUnion(shared.spaces.map { .space($0.id) })
        ids.formUnion(shared.profiles.map { .profile($0.id) })
        ids.formUnion(shared.tabs.filter(BrowserState.isShared).map { .tab($0.id) })
        ids.formUnion(shared.folders.map { .folder($0.id) })
        ids.formUnion(shared.archived.map { .archived($0.id) })
        return ids
    }

    /// The shared state these records describe. A record that doesn't read as its kind is skipped.
    /// Spaces and tabs come in their lists' order; ones a list doesn't name go last (for a tab, that's
    /// newest). Archived tabs come oldest first.
    public var shared: BrowserState.Shared {
        func models<Model: Decodable>(_ kind: SyncRecordID.Kind, _ type: Model.Type) -> [Model] {
            // Sorted, so what a list doesn't place comes out in the same order on every device.
            keys.filter { $0.kind == kind }.sorted { $0.name < $1.name }
                .compactMap { SyncJSON.decode(type, from: self[$0]!.fields) }
        }
        func ordered<Model: Identifiable>(_ models: [Model], by list: SyncRecordID) -> [Model] where Model.ID == UUID {
            var place: [UUID: Int] = [:]
            for (index, id) in (self[list]?.ids ?? []).enumerated() where place[id] == nil { place[id] = index }
            let listed = models.filter { place[$0.id] != nil }.sorted { place[$0.id]! < place[$1.id]! }
            return listed + models.filter { place[$0.id] == nil }
        }
        return BrowserState.Shared(
            spaces: ordered(models(.space, Space.self), by: .spaceOrder),
            profiles: models(.profile, Profile.self).sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) },
            tabs: ordered(models(.tab, Tab.self).filter(BrowserState.isShared), by: .tabOrder),
            folders: models(.folder, Folder.self),
            archived: models(.archived, ArchivedTab.self).sorted { ($0.archivedAt, $0.id.uuidString) < ($1.archivedAt, $1.id.uuidString) }
        )
    }
}
