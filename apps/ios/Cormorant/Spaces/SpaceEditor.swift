import CormorantCore
import SwiftUI

/// New Space and Edit Space: a sheet over Manage Spaces. Nothing changes until the checkmark; Cancel
/// leaves the Space as it was. A new Space opens once added (`BrowserStore.createSpace`), and Manage
/// Spaces closes with it.
struct SpaceEditor: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Space
    @State private var confirmingArchive = false
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool
    private let isNew: Bool

    /// New Space, starting from `look`.
    init(newWith look: (icon: SpaceIcon, color: Swatch)) {
        _draft = State(initialValue: Space(name: "", icon: look.icon, color: look.color))
        isNew = true
    }

    /// Edit Space.
    init(editing space: Space) {
        _draft = State(initialValue: space)
        isNew = false
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isHome: Bool { draft.id == Space.defaultID }
    /// The saved Space, for its name in the confirmations; nil once it's gone.
    private var saved: Space? { isNew ? nil : store.state.space(draft.id) }
    private var tabCount: Int { isNew ? 0 : store.state.tabCount(inSpace: draft.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                }
                .listRowInsets(EdgeInsets())

                Section("Name") {
                    TextField("Name", text: $draft.name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                }

                if isNew {
                    Section("Icon") {
                        SpaceIconPicker(icon: $draft.icon, color: draft.color)
                    }
                    Section("Color") {
                        SpaceColorPicker(color: $draft.color)
                    }
                } else {
                    Section("Appearance") {
                        NavigationLink {
                            iconAndColor
                        } label: {
                            Label {
                                Text("Icon and Color")
                            } icon: {
                                SpaceIconBadge(icon: draft.icon, color: draft.color, side: 30)
                            }
                        }
                    }
                }

                Section("Profile") {
                    NavigationLink {
                        ProfilePicker(profileID: $draft.profileID, spaceName: confirmName, saved: saved, tabCount: tabCount)
                    } label: {
                        ProfileRow(profile: draftProfile, detail: profileDetail)
                    }
                    .accessibilityIdentifier("SpaceProfile")
                }

                if !isNew, store.hasSpacesToSwitch, saved?.isArchived == false {
                    focusSection
                }

                if !isNew {
                    tabsSection
                    if !isHome { archiveAndDelete }
                }
            }
            .navigationTitle(isNew ? "New Space" : (trimmedName.isEmpty ? (saved?.name ?? "") : trimmedName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", systemImage: "checkmark", role: .confirm, action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { if isNew { nameFocused = true } }
        }
        // A half-typed new Space isn't swiped away by accident.
        .interactiveDismissDisabled(isNew ? !trimmedName.isEmpty : draft != saved)
    }

    /// The chosen profile; the default if it's gone (deleted from another window).
    private var draftProfile: Profile { store.state.profile(draft.profileID) ?? .default }

    /// Who else uses the chosen profile, or that a switch reloads the tabs here once saved.
    private var profileDetail: String {
        if let saved, draft.profileID != saved.profileID, tabCount > 0 {
            return tabCount == 1 ? "Its tab reloads when you save" : "Its \(tabCount) tabs reload when you save"
        }
        if let others = store.state.spaceNames(usingProfile: draft.profileID, except: draft.id) {
            return "Also used by \(others)"
        }
        return isNew ? "No other Space uses this profile" : "Only \(confirmName) uses this profile"
    }

    private var preview: some View {
        SpaceBarPreview(name: trimmedName, icon: draft.icon, color: draft.color, tabCount: tabCount)
    }

    /// Edit Space's Icon and Color page; New Space has the two pickers inline.
    private var iconAndColor: some View {
        Form {
            Section { preview }
                .listRowInsets(EdgeInsets())
            Section("Icon") {
                SpaceIconPicker(icon: $draft.icon, color: draft.color)
            }
            Section("Color") {
                SpaceColorPicker(color: $draft.color)
            }
        }
        .navigationTitle("Icon and Color")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Edit Space only

    /// Whether a Focus filter sends links from other apps here now. The app knows its filter is on and
    /// which Space it names, not which Focus it belongs to, so it doesn't say.
    private var isFocusTarget: Bool { store.focusFilter.spaceID == draft.id }

    /// The Focus filter: on now for this Space, or how to set one up (that's in iOS Settings).
    private var focusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Swatch.indigo.color, in: .rect(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus Filter")
                    Text(isFocusTarget ? "On now: links from other apps open in \(confirmName)" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isFocusTarget {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("FocusFilterRow")
        } header: {
            Text("Focus")
        } footer: {
            Text(isFocusTarget
                 ? "When the Focus ends, links open in the last Space you used."
                 : "To open links from other apps in \(confirmName) during a Focus, go to Settings › Focus, choose a Focus, then Add Filter › Cormorant › \(saved?.name ?? confirmName).")
        }
    }

    private var tabsSection: some View {
        Section {
            Picker(selection: $draft.archivePolicy) {
                // The same choices as Settings › Tabs; a time this build doesn't offer (a newer
                // build's) is kept among them unless another is chosen.
                ForEach(ArchivePolicy.choices(keeping: saved?.archivePolicy ?? draft.archivePolicy), id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            } label: {
                Label("Archive Idle Tabs After", systemImage: "clock.arrow.circlepath")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Tabs")
        } footer: {
            Text(archiveFooter)
        }
    }

    /// What the archive time does, and, when the time chosen is shorter than the one saved, which tabs
    /// it takes as soon as it applies: the archiver runs when the app comes back to the foreground.
    private var archiveFooter: String {
        var base = draft.archivePolicy.interval == nil
            ? "Tabs here stay open until you close them."
            : "Tabs you haven't looked at for this long move to the tab archive."
        // Off because Settings' switch is (it remembers a time to go back to), not by choice here.
        if draft.archivePolicy.interval == nil, let remembered = saved?.archivePolicyBeforeOff {
            base += " Archive Idle Tabs is off in Settings; turning it on there brings back \(remembered.label). Picking a time here turns it on for this Space alone."
        }
        guard let saved, draft.archivePolicy != saved.archivePolicy else { return base }
        let due = store.state.tabsDue(inSpace: draft.id, policy: draft.archivePolicy).count
        // Only when the new time takes more than the saved one would: otherwise nothing new to say.
        guard due > store.state.tabsDue(inSpace: draft.id).count else { return base }
        let tabs = due == 1 ? "1 tab here has" : "\(due) tabs here have"
        return base + " \(tabs) been idle longer than that, and will move the next time you come back to Cormorant."
    }

    private var archiveAndDelete: some View {
        Section {
            Button("Archive Space", systemImage: "archivebox") { confirmingArchive = true }
                .confirmationDialog("Archive \(confirmName)?", isPresented: $confirmingArchive,
                                    titleVisibility: .visible) {
                    Button("Archive \(confirmName)", action: archive)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(archiveMessage)
                }
            Button("Delete Space", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .foregroundStyle(.red)
                .confirmationDialog("Delete \(confirmName)?", isPresented: $confirmingDelete,
                                    titleVisibility: .visible) {
                    Button("Delete \(confirmName)", role: .destructive, action: delete)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(deleteMessage)
                }
        }
    }

    /// The name as it is in the field, or as saved while the field is blank.
    private var confirmName: String { trimmedName.isEmpty ? (saved?.name ?? "") : trimmedName }

    private var archiveMessage: String {
        let kept = switch tabCount {
        case 0: "It has no open tabs."
        case 1: "Its tab is kept, and doesn't archive while the Space is away."
        default: "Its \(tabCount) tabs are kept, and don't archive while the Space is away."
        }
        return "\(kept) \(confirmName) leaves the Spaces you switch between until you restore it from Archived in Spaces."
    }

    private var deleteMessage: String { Self.deleteMessage(tabCount: tabCount) }

    /// What deleting a Space does with its tabs: here and when Manage Spaces deletes an archived one.
    static func deleteMessage(tabCount: Int) -> String {
        let moved = switch tabCount {
        case 0: "It has no open tabs."
        case 1: "Its tab goes to the tab archive, where you can search for it and reopen it."
        default: "Its \(tabCount) tabs go to the tab archive, where you can search for them and reopen them."
        }
        return "\(moved) The Space and its settings are gone."
    }

    // MARK: Actions

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if isNew {
            // Closes Manage Spaces, and this with it.
            store.createSpace(name: trimmedName, icon: draft.icon, color: draft.color, profileID: draft.profileID)
        } else {
            commitEdits()
            dismiss()
        }
    }

    private func commitEdits() {
        store.updateSpace(draft.id, name: draft.name, icon: draft.icon, color: draft.color,
                          archivePolicy: draft.archivePolicy, profileID: draft.profileID)
    }

    /// Keeps what was changed here, then archives.
    private func archive() {
        commitEdits()
        store.archiveSpace(draft.id)
        dismiss()
    }

    private func delete() {
        store.deleteSpace(draft.id)
        dismiss()
    }
}
