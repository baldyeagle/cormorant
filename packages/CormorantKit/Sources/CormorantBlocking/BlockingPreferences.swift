import Foundation

/// User-facing blocking settings. Persisted by the app (UserDefaults in the app group).
public struct BlockingPreferences: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var enabledSources: Set<FilterListSource>
    /// Hosts (lowercased, no `www.`) where blocking is turned off.
    public var disabledHosts: Set<String>

    public init(isEnabled: Bool = true, enabledSources: Set<FilterListSource> = FilterListSource.defaultSet,
                disabledHosts: Set<String> = []) {
        self.isEnabled = isEnabled
        self.enabledSources = enabledSources
        self.disabledHosts = disabledHosts
    }

    public static let `default` = BlockingPreferences()

    /// Normalizes a host for comparison: lowercase, strips a leading `www.`.
    public static func normalize(host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        // Fully-qualified form `example.com.` is the same site.
        if normalized.count > 1 && normalized.hasSuffix(".") { normalized.removeLast() }
        if normalized.hasPrefix("www.") && normalized.count > 4 { normalized.removeFirst(4) }
        return normalized
    }

    /// Whether content blocking applies to pages on `host`. A nil host (e.g. `about:blank`) follows the
    /// global switch.
    public func isBlocking(host: String?) -> Bool {
        guard isEnabled else { return false }
        guard let host else { return true }
        return !disabledHosts.contains(Self.normalize(host: host))
    }

    public mutating func setBlocking(_ enabled: Bool, host: String) {
        let normalized = Self.normalize(host: host)
        guard !normalized.isEmpty else { return }
        if enabled {
            disabledHosts.remove(normalized)
        } else {
            disabledHosts.insert(normalized)
        }
    }
}
