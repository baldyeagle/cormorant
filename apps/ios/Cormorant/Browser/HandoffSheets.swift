import CormorantCore
import EventKit
import EventKitUI
import PassKit
import QuickLook
import SwiftUI

/// Puts up what a page handed over (Add to Wallet, a calendar file's events, an AR model in Quick
/// Look) over whatever is on screen: the caret sheet with the Downloads list stacked on it (Try
/// Again), the switcher, another handoff. A SwiftUI sheet on the browser screen can't come up while
/// another is, so these are presented from the top-most view controller instead.
@MainActor
final class HandoffPresenter {
    private var live: [Presentation] = []

    func present(pass: PKPass, onDismiss: @escaping () -> Void) {
        guard let controller = PKAddPassesViewController(pass: pass) else { return onDismiss() }
        let presentation = Presentation(onDismiss: onDismiss, presenter: self)
        controller.delegate = presentation
        show(controller, presentation)
    }

    func present(_ calendarImport: CalendarImport, onDismiss: @escaping () -> Void) {
        let presentation = Presentation(onDismiss: onDismiss, presenter: self)
        let host = UIHostingController<CalendarImportView?>(rootView: nil)
        host.rootView = CalendarImportView(calendarImport: calendarImport) { [weak host, weak presentation] in
            host?.dismiss(animated: true) { presentation?.finish() }
        }
        show(host, presentation)
    }

    /// Quick Look on `file`: AR, on a device that has it, for a model.
    func preview(_ file: URL, onDismiss: @escaping () -> Void) {
        let presentation = Presentation(onDismiss: onDismiss, presenter: self)
        presentation.previewItem = file
        let controller = QLPreviewController()
        controller.dataSource = presentation
        controller.delegate = presentation
        show(controller, presentation)
    }

    private func show(_ controller: UIViewController, _ presentation: Presentation) {
        guard let top = Self.topViewController() else { return presentation.finish() }
        live.append(presentation)
        top.present(controller, animated: true)
        // A swipe down: no callback from the controller itself.
        controller.presentationController?.delegate = presentation
    }

    fileprivate func ended(_ presentation: Presentation) {
        live.removeAll { $0 === presentation }
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// One handoff on screen: reports its end once, however it ends.
private final class Presentation: NSObject, UIAdaptivePresentationControllerDelegate, PKAddPassesViewControllerDelegate,
    QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    var previewItem: URL?
    private var onDismiss: (() -> Void)?
    private weak var presenter: HandoffPresenter?

    init(onDismiss: @escaping () -> Void, presenter: HandoffPresenter) {
        self.onDismiss = onDismiss
        self.presenter = presenter
    }

    func finish() {
        let done = onDismiss
        onDismiss = nil
        presenter?.ended(self)
        done?()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

    func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
        controller.dismiss(animated: true) { [weak self] in self?.finish() }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewItem == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        (previewItem ?? URL(filePath: "/")) as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) { finish() }
}

/// The events of a calendar file: one goes straight to the New Event editor; several are listed to
/// add one at a time, as Safari does. The editor runs outside the app, so adding needs no calendar
/// access (and no permission prompt).
struct CalendarImportView: View {
    let calendarImport: CalendarImport
    let onDone: () -> Void
    @State private var editing: EditedEvent?
    @State private var added: Set<Int> = []

    private struct EditedEvent: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        if calendarImport.events.count == 1, let event = calendarImport.events.first {
            EventEditor(event: event) { _ in onDone() }
                .ignoresSafeArea()
        } else {
            list
        }
    }

    private var list: some View {
        NavigationStack {
            List(Array(calendarImport.events.enumerated()), id: \.offset) { index, event in
                Button {
                    editing = EditedEvent(index: index)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(.body).foregroundStyle(.primary)
                            Text(Self.when(event)).font(.footnote).foregroundStyle(.secondary)
                            if let location = event.location {
                                Text(location).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if event.recurrence != nil {
                                Label("Repeats; adds the first one", systemImage: "repeat")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: added.contains(index) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundStyle(added.contains(index) ? Color.green : Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityValue(added.contains(index) ? "Added" : "")
                .accessibilityHint("Opens it in a new event to add")
            }
            .navigationTitle("\(calendarImport.events.count) Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .sheet(item: $editing) { edited in
            EventEditor(event: calendarImport.events[edited.index]) { action in
                if action == .saved { added.insert(edited.index) }
                editing = nil
            }
            .ignoresSafeArea()
        }
    }

    private static func when(_ event: CalendarEvent) -> String {
        if event.isAllDay {
            let last = event.end.addingTimeInterval(-1)
            let sameDay = Calendar.current.isDate(event.start, inSameDayAs: last)
            let day = event.start.formatted(date: .abbreviated, time: .omitted)
            return sameDay ? "\(day), all day" : "\(day) – \(last.formatted(date: .abbreviated, time: .omitted))"
        }
        return (event.start..<max(event.end, event.start)).formatted(.interval.day().month().year().hour().minute())
    }
}

/// The system's New Event editor, filled in from `event`.
struct EventEditor: UIViewControllerRepresentable {
    let event: CalendarEvent
    let onFinish: (EKEventEditViewAction) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let controller = EKEventEditViewController()
        controller.eventStore = store
        let new = EKEvent(eventStore: store)
        new.title = event.title
        new.isAllDay = event.isAllDay
        new.startDate = event.start
        // EventKit's all-day end is within the last day; the file's is the day after.
        new.endDate = event.isAllDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end
        new.location = event.location
        new.notes = event.notes
        new.url = event.url
        controller.event = new
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: (EKEventEditViewAction) -> Void
        init(onFinish: @escaping (EKEventEditViewAction) -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action)
        }
    }
}
