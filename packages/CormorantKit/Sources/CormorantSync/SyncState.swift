/// Observable state of cross-device sync.
public enum SyncState: Hashable, Sendable {
    /// Off (the default), or not possible in this build.
    case disabled
    case idle
    case syncing
    /// The cloud's records are encrypted with a key iCloud Keychain hasn't brought to this device yet.
    /// Nothing is sent or changed until it arrives.
    case waitingForKey
    /// The device isn't signed into iCloud.
    case noAccount
    case failed(String)
}
