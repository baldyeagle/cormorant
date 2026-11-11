import CormorantCore
import SwiftUI
import UIKit

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

    init(icon: Icon, message: String, spokenText: String? = nil, note: Note? = nil, leadingAction: Action? = nil,
         actions: [Action]) {
        self.icon = icon
        self.message = message
        self.spokenText = spokenText
        self.note = note
        self.leadingAction = leadingAction
        self.actions = actions
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

/// Draws the store's toast, if any, at the bottom of the space it's given, and takes it away when it's
/// swiped off. Hidden while `isSuppressed` (the toast itself stays up for the other host).
struct ToastHost: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isSuppressed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let toast = store.toast, !isSuppressed {
                ToastView(toast: toast, onDismiss: { store.dismissToast(toast.id) }, onHold: store.holdToast)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 12)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3), value: store.toast?.id)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3), value: isSuppressed)
    }
}

/// A glass capsule like the bar's controls: any leading button, the icon, the message, then its buttons.
/// At accessibility text sizes the buttons, the leading one first, go under the message. Swipe down or sideways to dismiss it.
private struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var iconSide: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var minHeight: CGFloat = 52
    @State private var drag: CGSize = .zero
    /// What VoiceOver is on, if anything in the toast: the toast stays up meanwhile.
    @AccessibilityFocusState private var focus: String?
    let onHold: (Bool) -> Void

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) {
                if !typeSize.isAccessibilitySize, let back = toast.leadingAction { button(back) }
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.message)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .accessibilityLabel(toast.spokenText ?? toast.message)
                        .accessibilityFocused($focus, equals: "message")
                        .accessibilityAction(named: "Dismiss", onDismiss)
                    if let note = toast.note {
                        Label(note.text, systemImage: note.symbol)
                            .font(.caption)
                            .labelStyle(ToastNoteLabelStyle())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityFocused($focus, equals: "note")
                            .accessibilityAction(named: "Dismiss", onDismiss)
                            .accessibilityIdentifier("Toast.note")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if typeSize.isAccessibilitySize, let back = toast.leadingAction { button(back) }
                ForEach(toast.actions) { button($0) }
            }
            // The buttons take their room first; the message wraps in what's left.
            .layoutPriority(1)
        }
        .padding(.leading, toast.leadingAction == nil || typeSize.isAccessibilitySize ? 10 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: minHeight)
        // In dark mode the glass takes on the page under it, a light grey over a white page that left
        // white text unreadable: the app's dark (#030712) under the content keeps it legible anywhere.
        .background {
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: minHeight / 2, style: .continuous)
                    .fill(Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255).opacity(0.72))
            }
        }
        .glassEffect(glass, in: .rect(cornerRadius: minHeight / 2, style: .continuous))
        .offset(x: drag.width, y: drag.height)
        .opacity(1 - min(1, max(abs(drag.width) / 200, drag.height / 80)) * 0.6)
        .gesture(swipeAway)
        .accessibilityElement(children: .contain)
        // Scrub (two-finger Z) dismisses, from any element in it.
        .accessibilityAction(.escape, onDismiss)
        .accessibilityIdentifier("Toast")
        .onChange(of: focus != nil) { _, held in onHold(held) }
        .onDisappear { if focus != nil { onHold(false) } }
    }

    private func button(_ action: Toast.Action) -> some View {
        Button {
            onDismiss()
            action.perform()
        } label: {
            if let space = action.space {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left")
                    SpaceIconBadge(icon: space.icon, color: space.color, side: min(iconSide * 0.75, 33))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(action.title)
            } else {
                Text(action.title)
            }
        }
        .buttonStyle(ToastButtonStyle())
        .accessibilityFocused($focus, equals: action.title)
        .accessibilityAction(named: "Dismiss", onDismiss)
        .accessibilityIdentifier("Toast.\(action.title)")
    }

    @ViewBuilder private var icon: some View {
        switch toast.icon {
        case .space(let space):
            SpaceIconBadge(icon: space.icon, color: space.color, side: min(iconSide, 44))
        case .symbol(let name):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .frame(width: min(iconSide, 44), height: min(iconSide, 44))
                .accessibilityHidden(true)
        }
    }

    private var glass: Glass {
        toast.tint.map { .regular.tint($0.barTint(in: colorScheme)) } ?? .regular
    }

    /// Follows the finger down or sideways (up only grudgingly), and lets go past a short way.
    private var swipeAway: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let t = value.translation
                drag = abs(t.width) > abs(t.height)
                    ? CGSize(width: t.width, height: 0)
                    : CGSize(width: 0, height: t.height > 0 ? t.height : t.height * 0.15)
            }
            .onEnded { value in
                let t = value.predictedEndTranslation
                if abs(drag.width) > 0 ? abs(t.width) > 120 : t.height > 40 {
                    onDismiss()
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) { drag = .zero }
                }
            }
    }
}

/// The note's symbol a little smaller than its text, close beside it.
private struct ToastNoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The toast's buttons: the app's tint on a pale capsule, 44pt tall to the touch.
private struct ToastButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6), in: .capsule)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(.capsule.inset(by: -4))
    }
}
