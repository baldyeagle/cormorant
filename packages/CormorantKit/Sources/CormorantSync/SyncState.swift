/// Observable state of cross-device sync.
public enum SyncState: Hashable, Sendable {
    case disabled
    case idle
    case syncing
    case failed(String)
}
