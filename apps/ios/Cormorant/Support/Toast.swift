import CormorantCore
import Foundation

/// A short note that something happened between Spaces (a tab moved to another, taking you with it; a
/// link opened in one), with a button or two to act on it. Shown by `BrowserStore.showToast(_:)` and drawn by
/// `ToastHost`, which the browser puts above its bar and the switcher above its toolbar.
struct Toast: Identifiable {
    struct Action: Identifiable {
        let title: String
        /// Drawn as ← and this Space's badge in place of the title, which VoiceOver still reads.
        let space: Space?
        let perform: @MainActor () -> Void
        var id: String { title }

        init(_ title: String, space: Space? = nil, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.space = space
            self.perform = perform
        }
    }

    enum Icon {
        /// The Space's badge; the toast's glass takes a trace of its color, as the bar's does.
        case space(Space)
        case symbol(String)
        /// Incognito's sunglasses, on a black badge: Incognito may have closed, so it's no Space to act on.
        case incognito
    }

    /// A fetch the toast follows: a line under the message counting it up ("42.1 MB of 183.4 MB") and
    /// a bar along its bottom edge, read a couple of times a second while it's up.
    struct Transfer {
        let current: @MainActor () -> (received: Int64, expected: Int64?)

        init(current: @escaping @MainActor () -> (received: Int64, expected: Int64?)) {
            self.current = current
        }
    }

    /// A small line under the message saying why: "Focus" when a Focus filter chose the Space.
    struct Note {
        let text: String
        let symbol: String
    }

    let id = UUID()
    let icon: Icon
    let message: String
    /// What VoiceOver reads for a message cut short to leave its buttons room ("Moved to Work" for
    /// "Moved"); nil when the message says it all.
    var spokenText: String?
    var note: Note?
    /// A button before the icon: back to the Space a move left.
    var leadingAction: Action?
    let actions: [Action]
    /// The tab every button acts on: the toast comes down once that tab closes (a back swipe can close
    /// it with the toast still up).
    var tabID: UUID?
    /// Shown in place of the note.
    var transfer: Transfer?
    /// Up until it's swiped away or taken down, rather than for a few seconds: for as long as a fetch
    /// it follows takes.
    var staysUp: Bool

    init(icon: Icon, message: String, spokenText: String? = nil, note: Note? = nil, leadingAction: Action? = nil,
         actions: [Action], tabID: UUID? = nil, transfer: Transfer? = nil, staysUp: Bool = false) {
        self.icon = icon
        self.message = message
        self.spokenText = spokenText
        self.note = note
        self.leadingAction = leadingAction
        self.actions = actions
        self.tabID = tabID
        self.transfer = transfer
        self.staysUp = staysUp
    }

    /// Every button, in the order they're drawn.
    var allActions: [Action] { (leadingAction.map { [$0] } ?? []) + actions }

    /// The message and note, as VoiceOver announces them: "Opened in Work, Focus".
    var spokenMessage: String {
        let text = spokenText ?? message
        return note.map { "\(text), \($0.text)" } ?? text
    }

    var tint: Swatch? {
        if case .space(let space) = icon { space.color } else { nil }
    }
}
