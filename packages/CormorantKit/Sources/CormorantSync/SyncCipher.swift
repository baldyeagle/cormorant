import CryptoKit
import Foundation

/// The key every device encrypts records with. It lives in iCloud Keychain, never in CloudKit.
public struct SyncKey: Sendable, Equatable {
    /// Names the key without giving it away (from its hash), so a device can tell which key a record
    /// needs and whether it has it.
    public let id: String
    public let data: Data

    /// A new random 256-bit key.
    public init() {
        self.init(unchecked: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Nil unless `data` is 32 bytes.
    public init?(data: Data) {
        guard data.count == 32 else { return nil }
        self.init(unchecked: data)
    }

    private init(unchecked data: Data) {
        self.data = data
        id = SHA256.hash(data: Data("cormorant-sync-key-id".utf8) + data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var symmetric: SymmetricKey { SymmetricKey(data: data) }
}

/// A record as CloudKit stores it. Apple sees these four fields: nothing of what the record is.
public struct SealedRecord: Sendable, Equatable {
    /// A hash of the record's ID.
    public var name: String
    public var keyID: String
    /// The format (`SyncCipher.version`). A device leaves alone a record in a format newer than its own.
    public var version: Int
    public var payload: Data
    /// What the cloud gave this copy of the record, to hand back when saving over it: the cloud
    /// refuses a save whose tag isn't its latest. Nil for a record the cloud doesn't have yet.
    public var tag: Data?

    public init(name: String, keyID: String, version: Int, payload: Data, tag: Data? = nil) {
        self.name = name
        self.keyID = keyID
        self.version = version
        self.payload = payload
        self.tag = tag
    }
}

public enum SyncCipherError: Error, Equatable, Sendable {
    /// Encrypted with a key this device doesn't have (yet: iCloud Keychain brings it).
    case missingKey(id: String)
    /// Written by a newer build in a format this one can't read.
    case newerVersion(Int)
    /// Not what a device of ours wrote: altered, moved under another name, or damaged.
    case unreadable
}

/// Encrypts records for the cloud: AES-256-GCM, a fresh nonce each time, the record's name, format and
/// key ID authenticated with it, so a record can't be passed off as another.
public enum SyncCipher {
    public static let version = 1
    /// Plaintext is padded to a multiple of this, so a record's size says little about its content.
    static let padding = 256

    /// What a record is called in the cloud. IDs are random UUIDs, so the hash can't be reversed; the
    /// few fixed ones (Home, the default profile, the lists) are the same for everybody.
    public static func name(for id: SyncRecordID) -> String {
        SHA256.hash(data: Data("cormorant-sync-record:\(id.name)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private struct Plaintext: Codable {
        var id: SyncRecordID
        var fields: [String: JSONValue]
    }

    public static func seal(_ record: SyncRecord, id: SyncRecordID, with key: SyncKey, tag: Data? = nil) throws -> SealedRecord {
        var plaintext = try SyncJSON.encoder().encode(Plaintext(id: id, fields: record.fields))
        // JSON ignores trailing spaces.
        let short = (padding - plaintext.count % padding) % padding
        plaintext.append(contentsOf: repeatElement(UInt8(ascii: " "), count: short))
        let name = name(for: id)
        let box = try AES.GCM.seal(plaintext, using: key.symmetric,
                                   authenticating: authenticated(name: name, keyID: key.id, version: version))
        guard let payload = box.combined else { throw SyncCipherError.unreadable }
        return SealedRecord(name: name, keyID: key.id, version: version, payload: payload, tag: tag)
    }

    /// Decrypts with whichever of `keys` the record names.
    public static func open(_ sealed: SealedRecord, with keys: [SyncKey]) throws -> (id: SyncRecordID, record: SyncRecord) {
        guard sealed.version <= version else { throw SyncCipherError.newerVersion(sealed.version) }
        guard let key = keys.first(where: { $0.id == sealed.keyID }) else { throw SyncCipherError.missingKey(id: sealed.keyID) }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.payload)
            let data = try AES.GCM.open(box, using: key.symmetric,
                                        authenticating: authenticated(name: sealed.name, keyID: sealed.keyID, version: sealed.version))
            let plaintext = try SyncJSON.decoder().decode(Plaintext.self, from: data)
            guard name(for: plaintext.id) == sealed.name else { throw SyncCipherError.unreadable }
            return (plaintext.id, SyncRecord(fields: plaintext.fields))
        } catch {
            throw SyncCipherError.unreadable
        }
    }

    private static func authenticated(name: String, keyID: String, version: Int) -> Data {
        Data("\(version)|\(keyID)|\(name)".utf8)
    }
}
