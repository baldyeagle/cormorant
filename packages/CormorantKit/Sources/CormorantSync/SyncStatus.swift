import Foundation

/// What Settings says about sync, on the iPhone and the Mac.
public struct SyncStatus: Equatable, Sendable {
    public var text: String
    /// Something the user has to see to (shown in the warning color).
    public var needsAttention = false
    /// Offers Try Again.
    public var canRetry = false

    init(text: String, needsAttention: Bool = false, canRetry: Bool = false) {
        self.text = text
        self.needsAttention = needsAttention
        self.canRetry = canRetry
    }

    /// Nil while sync is off: Settings shows the switch alone.
    public init?(_ state: SyncState) {
        switch state {
        case .disabled: return nil
        case .idle: text = "Up to date"
        case .syncing: text = "Syncing…"
        case .waitingForKey:
            text = "Waiting for the encryption key. Turn on Passwords & Keychain in iCloud settings on this device."
            needsAttention = true
        case .noAccount:
            text = "Sign in to iCloud to sync."
            needsAttention = true
        case .failed(let message):
            text = message
            needsAttention = true
            canRetry = true
        }
    }

    /// Under the switch. `device` is "iPhone" or "Mac".
    public static func explanation(device: String) -> String {
        let other = device == "Mac" ? "iPhone" : "Mac"
        let this = device == "Mac" ? "this Mac" : "this device"
        return "Spaces, open tabs and the tab archive stay the same on your \(device) and \(other). "
            + "They're encrypted on \(this) before they're sent; the key is kept in iCloud Keychain. "
            + "Incognito tabs and sign-ins never leave \(this)."
    }
}
