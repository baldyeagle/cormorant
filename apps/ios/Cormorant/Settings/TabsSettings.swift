import CormorantCore
import SwiftUI

/// Archive Idle Tabs: one switch that turns auto-archive off (or back on) everywhere, then the time.
/// With one Space the time is a picker right here; with several, each Space's time is on its own page
/// (the same `Space.archivePolicy` Edit Space sets). Spaces never archive on their own; only tabs do.
struct TabsSettings: View {
    @Environment(BrowserStore.self) private var store
    /// Each Space's time when Settings opened, so a change can say which tabs it will now take.
    @State private var opening: [UUID: ArchivePolicy]?

    private var state: BrowserState { store.state }
    private var spaces: [Space] { state.switchableSpaces }

    var body: some View {
        Section {
            Toggle("Archive Idle Tabs", isOn: Binding(
                get: { state.archivesIdleTabs },
                set: { store.setArchivesIdleTabs($0) }
            ))
            // Dimmed while off, showing the time that comes back; not removed, so Time per Space stays
            // put when choosing Off there for the last Space turns the switch off.
            if spaces.count == 1, let home = timesWhenOn.switchableSpaces.first {
                ArchiveTimePicker(space: home, offersOff: false) {
                    Text("After")
                }
                .disabled(!state.archivesIdleTabs)
            } else {
                NavigationLink {
                    ArchiveTimesBySpace(opening: opening ?? [:])
                } label: {
                    LabeledContent("Time per Space", value: timesSummary)
                }
                .disabled(!state.archivesIdleTabs)
            }
        } header: {
            Text("Tabs")
        } footer: {
            Text(footer)
        }
        .onAppear { if opening == nil { opening = Dictionary(state.spaces.map { ($0.id, $0.archivePolicy) }) { a, _ in a } } }
    }

    /// The state as it is with the switch on, or as turning it on would leave it.
    private var timesWhenOn: BrowserState {
        guard !state.archivesIdleTabs else { return state }
        var resumed = state
        resumed.resumeArchivingIdleTabs()
        return resumed
    }

    /// The time every Space you can switch to shares (with the switch on), or "Varies".
    private var timesSummary: String {
        let times = Set(timesWhenOn.switchableSpaces.map(\.archivePolicy))
        return times.count == 1 ? times.first!.label : "Varies"
    }

    private var footer: String {
        let several = spaces.count > 1
        let base = switch (state.archivesIdleTabs, several) {
        case (true, false): "Tabs you haven't looked at for this long move to the tab archive."
        case (false, false): "Tabs stay open until you close them."
        case (true, true): "Tabs you haven't looked at for their Space's time move to the tab archive."
        case (false, true): "Tabs in every Space stay open until you close them."
        }
        var text = several ? base + " Spaces never archive on their own." : base
        let now = Date.now
        let due = spaces.reduce(0) { $0 + ArchiveNote.newlyDue(in: $1, of: state, opening: opening, now: now) }
        if let note = ArchiveNote.text(due: due, in: nil, eachSpace: several) { text += " " + note }
        return text
    }
}

/// Each Space you can switch to, with its time: what Edit Space's Archive Idle Tabs After sets.
private struct ArchiveTimesBySpace: View {
    @Environment(BrowserStore.self) private var store
    let opening: [UUID: ArchivePolicy]

    private var state: BrowserState { store.state }

    var body: some View {
        Form {
            Section {
                ForEach(state.switchableSpaces) { space in
                    ArchiveTimePicker(space: space, offersOff: true) {
                        Label {
                            Text(space.name.isEmpty ? "Untitled Space" : space.name)
                        } icon: {
                            Image(systemName: space.icon.rawValue)
                                .foregroundStyle(Color(space.color.rgb))
                                .accessibilityHidden(true)
                        }
                    }
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("Archive Idle Tabs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        var text = "Tabs you haven't looked at for this long move to the tab archive. Spaces never archive on their own."
        if !state.archivedSpaces.isEmpty { text += " Archived Spaces keep their tabs until you restore them." }
        let now = Date.now
        for space in state.switchableSpaces {
            let due = ArchiveNote.newlyDue(in: space, of: state, opening: opening, now: now)
            if let note = ArchiveNote.text(due: due, in: space.name, eachSpace: false) { text += " " + note }
        }
        return text
    }
}

/// A Space's time as a menu of `ArchivePolicy.offered`, without Off where the Archive Idle Tabs switch
/// is right beside it. A time this build doesn't offer (a newer build's) is kept unless another is chosen.
private struct ArchiveTimePicker<Title: View>: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    let offersOff: Bool
    @ViewBuilder let title: Title

    private var choices: [ArchivePolicy] {
        ArchivePolicy.choices(keeping: space.archivePolicy)
            .filter { $0 != .off || offersOff || space.archivePolicy == .off }
    }

    var body: some View {
        Picker(selection: Binding(
            get: { space.archivePolicy },
            set: { store.setArchivePolicy($0, forSpace: space.id) }
        )) {
            ForEach(choices, id: \.self) { Text($0.label).tag($0) }
        } label: {
            title
        }
        .pickerStyle(.menu)
    }
}

/// What a shorter time takes: tabs already idle longer move the next time the app comes back (the
/// archiver runs then), with their idle time as it was.
private enum ArchiveNote {
    /// As Edit Space counts: every tab the Space's time takes at the next foreground, once that's more
    /// than the time it had when Settings opened would take; else 0.
    static func newlyDue(in space: Space, of state: BrowserState, opening: [UUID: ArchivePolicy]?, now: Date) -> Int {
        guard let opening else { return 0 }
        let due = state.tabsDue(inSpace: space.id, now: now).count
        return due > state.tabsDue(inSpace: space.id, policy: opening[space.id], now: now).count ? due : 0
    }

    /// Nil when nothing is due. `space` names the Space (Time per Space, where "that" would point at no
    /// one time); `eachSpace` says each goes by its own time.
    static func text(due: Int, in space: String?, eachSpace: Bool) -> String? {
        guard due > 0 else { return nil }
        let tabs = due == 1 ? "1 tab" : "\(due) tabs"
        let name = space.map { $0.isEmpty ? "Untitled Space" : $0 }
        let place = name.map { " in \($0)" } ?? ""
        let verb = due == 1 ? "has" : "have"
        let limit = eachSpace ? "their Space's time" : name.map { "\($0)'s time" } ?? "that"
        return "\(tabs)\(place) \(verb) been idle longer than \(limit), and will move the next time you come back to Cormorant."
    }
}
