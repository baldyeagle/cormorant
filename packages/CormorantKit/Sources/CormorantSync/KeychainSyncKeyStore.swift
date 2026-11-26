import Foundation
import Security

public struct SyncKeychainError: Error, LocalizedError, Equatable, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The keychain couldn't be used: \(message)."
    }
}

/// The keys in iCloud Keychain: generic passwords marked synchronizable, so every device signed into
/// the account with iCloud Keychain on gets them, end to end encrypted whatever else is set. One item
/// per key, under the key's ID; none is ever deleted, so any record ever written stays readable.
public struct KeychainSyncKeyStore: SyncKeyStore {
    private let service: String

    public init(service: String = "dev.baldyeagle.cormorant.sync-key") {
        self.service = service
    }

    private var base: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: true,
            // The iOS-style keychain on the Mac too: the only one iCloud Keychain syncs.
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func keys() throws -> [SyncKey] {
        var query = base
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess else { throw SyncKeychainError(status: status) }
        let accounts = (found as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        return try accounts.compactMap { account in
            var query = base
            query[kSecAttrAccount] = account
            query[kSecMatchLimit] = kSecMatchLimitOne
            query[kSecReturnData] = true
            var data: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &data)
            guard status != errSecItemNotFound else { return nil }
            guard status == errSecSuccess else { throw SyncKeychainError(status: status) }
            // An item that isn't a key of ours under its own ID is passed over.
            guard let key = (data as? Data).flatMap(SyncKey.init(data:)), key.id == account else { return nil }
            return key
        }
    }

    public func add(_ key: SyncKey) throws {
        var item = base
        item[kSecAttrAccount] = key.id
        item[kSecAttrLabel] = "Cormorant Sync Key"
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecValueData] = key.data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw SyncKeychainError(status: status) }
    }
}
