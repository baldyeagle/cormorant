import CormorantCore
import Foundation

/// Locations and defaults shared with the share extension through the app-group container.
public enum AppGroupStorage {
    public static let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            ?? URL.cachesDirectory
    }

    static var blockingCacheDirectory: URL {
        containerURL.appending(path: "blocking", directoryHint: .isDirectory)
    }

    public static func load<Value: Decodable>(_ type: Value.Type, key: String, from defaults: UserDefaults = defaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public static func save<Value: Encodable>(_ value: Value?, key: String, to defaults: UserDefaults = defaults) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
