import Foundation
import os

/// Any JSON value. A synced record is a dictionary of these, so two devices' edits merge field by
/// field, and a field a newer build added passes through a build that doesn't know it.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The JSON coders records are made with. Dates are `timeIntervalSinceReferenceDate` doubles, as in
/// the state file, which round-trip a `Date` exactly.
enum SyncJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
        return decoder
    }

    /// `value`'s JSON object, or nil when it doesn't encode as one. Remembered by value: the state's
    /// records are made again at every round and after every change, nearly all of them unchanged.
    static func fields(of value: some Encodable & Hashable & Sendable) -> [String: JSONValue]? {
        let key = AnyHashable(value)
        if let known = cache.withLockUnchecked({ $0[key] }) { return known }
        guard let data = try? encoder().encode(value),
              let fields = try? decoder().decode([String: JSONValue].self, from: data) else { return nil }
        cache.withLockUnchecked {
            if $0.count >= cacheLimit { $0.removeAll(keepingCapacity: true) }
            $0[key] = fields
        }
        return fields
    }

    private static let cacheLimit = 20_000
    private static let cache = OSAllocatedUnfairLock<[AnyHashable: [String: JSONValue]]>(uncheckedState: [:])

    static func decode<Value: Decodable>(_ type: Value.Type, from fields: [String: JSONValue]) -> Value? {
        guard let data = try? encoder().encode(fields) else { return nil }
        return try? decoder().decode(type, from: data)
    }
}
