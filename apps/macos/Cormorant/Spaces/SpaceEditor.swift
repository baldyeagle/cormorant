import CormorantBrowser
import CormorantCore
import SwiftUI

/// New Space and Edit Space, in a popover off the bottom row. Edit Space applies each change as it's
/// made and closes on a click away; a profile that reloads the Space's tabs waits on Switch. New
/// Space adds nothing until Create Space, then opens the command bar in it.
struct SpaceEditor: View {
    let target: SpaceEditorTarget
    let store: BrowserStore
    let commands: WindowCommands
    @State private var draft: Space
    /// The archive time when the editor opened, to say what a shorter one will take.
    @State private var openedPolicy: ArchivePolicy
    /// Chosen, waiting on the reload warning's Switch.
    @State private var pendingProfile: Profile?
    @State private var newProfile: NewProfile?
    @FocusState private var nameFocused: Bool

    private static let newProfileTag = UUID()

    private struct NewProfile {
        var name = ""
        var color: Swatch
    }

    init(target: SpaceEditorTarget, store: BrowserStore, commands: WindowCommands) {
        self.target = target
        self.store = store
        self.commands = commands
        let space: Space
        switch target {
        case .new:
            let look = store.state.suggestedNewSpaceLook
            space = Space(name: "", icon: look.icon, color: look.color,
                          archivePolicy: store.state.archivesIdleTabs ? .oneDay : .off)
        case .edit(let id):
            // Gone: a stand-in the engine ignores, never Home.
            space = store.state.space(id) ?? Space(name: "")
        }
        _draft = State(initialValue: space)
        _openedPolicy = State(initialValue: space.archivePolicy)
    }

    private var isNew: Bool { target == .new }
    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let newProfile {
                newProfileForm(newProfile)
            } else {
                spaceForm
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { if isNew { nameFocused = true } }
        // Its tabs closed while the warning was up: nothing reloads now, so it's simply chosen.
        .onChange(of: pendingWarning == nil) { _, gone in
            guard gone, let pendingProfile else { return }
            draft.profileID = pendingProfile.id
            self.pendingProfile = nil
        }
        .onChange(of: draft) { _, space in
            guard !isNew else { return }
            store.updateSpace(space.id, name: space.name, icon: space.icon, color: space.color,
                              archivePolicy: space.archivePolicy, profileID: space.profileID)
        }
    }

    @ViewBuilder private var spaceForm: some View {
        if isNew {
            Text("New Space").font(.headline)
        }
        TextField("Name", text: $draft.name, prompt: Text(isNew ? "Name" : store.state.space(draft.id)?.name ?? ""))
            .textFieldStyle(.roundedBorder)
            .focused($nameFocused)
        IconGrid(icon: $draft.icon, color: draft.color)
        ColorRow(color: $draft.color)
        row("Profile") { profilePicker }
        if let pendingProfile, let warning = pendingWarning {
            ProfileWarning(text: warning) {
                draft.profileID = pendingProfile.id
                self.pendingProfile = nil
            } cancel: {
                self.pendingProfile = nil
            }
        }
        row("Archive idle tabs after") {
            Picker("Archive idle tabs after", selection: $draft.archivePolicy) {
                ForEach(ArchivePolicy.choices(keeping: openedPolicy), id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        if !isNew, let note = store.state.idleTabsNote(inSpace: draft.id, comparedWith: openedPolicy) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isNew {
            HStack {
                Spacer()
                Button("Create Space", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        } else {
            Divider()
            HStack {
                Button("Archive", systemImage: "archivebox") { remove(.archive) }
                    .accessibilityLabel("Archive Space")
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { remove(.delete) }
                    .foregroundStyle(isHome ? Color.secondary : .red)
                    .accessibilityLabel("Delete Space")
            }
            .buttonStyle(.bordered)
            // Home is where tabs go when nowhere else will have them: it stays.
            .disabled(isHome)
            .help(isHome ? "Home can't be archived or deleted" : "")
        }
    }

    private var isHome: Bool { draft.id == Space.defaultID }

    private var pendingWarning: String? {
        pendingProfile.flatMap { store.state.profileSwitchWarning(spaceID: draft.id, to: $0.id) }
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: Binding(get: { pendingProfile?.id ?? draft.profileID }, set: choose)) {
            ForEach(store.state.profilesInOrder) { profile in
                Label {
                    Text(profile.name)
                } icon: {
                    Image(nsImage: ProfileMonogram.menuImage(for: profile))
                }
                .tag(profile.id)
            }
            Divider()
            Text("New Profile…").tag(Self.newProfileTag)
        }
        .labelsHidden()
        .fixedSize()
    }

    private func newProfileForm(_ profile: NewProfile) -> some View {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            Text("New Profile").font(.headline)
            TextField("Name", text: Binding(get: { profile.name }, set: { newProfile?.name = $0 }), prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onAppear { nameFocused = true }
            ColorRow(color: Binding(get: { profile.color }, set: { newProfile?.color = $0 }))
            Text("\(name.isEmpty ? "A new profile" : name) has its own logins, cookies and website data, and starts signed out of every site.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { newProfile = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create Profile") {
                    guard let made = store.createProfile(name: name, color: profile.color) else { return }
                    newProfile = nil
                    choose(made.id)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
    }

    // MARK: Actions

    /// Straight in, unless it reloads the Space's tabs: then the warning's Switch does it.
    private func choose(_ profileID: UUID) {
        if profileID == Self.newProfileTag {
            newProfile = NewProfile(color: store.state.suggestedNewProfileColor)
            return
        }
        pendingProfile = nil
        guard profileID != draft.profileID else { return }
        if store.state.profileSwitchWarning(spaceID: draft.id, to: profileID) != nil {
            pendingProfile = store.state.profile(profileID)
        } else {
            draft.profileID = profileID
        }
    }

    private func create() {
        guard store.createSpace(name: trimmedName, icon: draft.icon, color: draft.color, profileID: draft.profileID,
                                archivePolicy: draft.archivePolicy == openedPolicy ? nil : draft.archivePolicy) != nil
        else { return }
        commands.spaceEditor = nil
        store.newTab()
    }

    private func remove(_ kind: SpaceRemoval.Kind) {
        commands.spaceEditor = nil
        guard let space = store.state.space(draft.id) else { return }
        commands.spaceRemoval = SpaceRemoval(kind, space, in: store.state)
    }
}

/// Before a new profile reloads a Space's tabs: what happens to them, and Switch or Cancel.
private struct ProfileWarning: View {
    let text: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "arrow.clockwise")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Switch", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Swatch.gold.color.opacity(0.14), in: .rect(cornerRadius: 9))
    }
}

/// The twelve icons, six to a row; the chosen one filled with the Space's color.
private struct IconGrid: View {
    @Binding var icon: SpaceIcon
    let color: Swatch

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
            ForEach(SpaceIcon.allCases, id: \.self) { option in
                let isChosen = option == icon
                Button { icon = option } label: {
                    Image(systemName: option.rawValue)
                        .font(.system(size: 14))
                        .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(isChosen ? AnyShapeStyle(color.color) : AnyShapeStyle(.fill.tertiary),
                                    in: .rect(cornerRadius: 8))
                        .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(option.name)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }
}

/// The eight colors in a row; the chosen one ringed.
private struct ColorRow: View {
    @Binding var color: Swatch

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Swatch.allCases, id: \.self) { option in
                let isChosen = option == color
                Button { color = option } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(Circle().stroke(option.color, lineWidth: 2).opacity(isChosen ? 1 : 0))
                        .frame(maxWidth: .infinity)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(option.name)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }
}
