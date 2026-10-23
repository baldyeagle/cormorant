import SwiftUI

/// Find on Page uses the system find navigator (`UIFindInteraction` on the tab's web view, opened by
/// `TabSession.runPendingAction()`), so this draws nothing. Kept as the slot above the bottom bar
/// in case Cormorant ever needs its own find UI.
struct FindOnPageBar: View {
    let session: TabSession?

    var body: some View {
        EmptyView()
    }
}
