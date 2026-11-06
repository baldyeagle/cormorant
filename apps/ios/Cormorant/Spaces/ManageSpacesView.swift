import CormorantCore
import SwiftUI

/// Manage Spaces: the Spaces you switch between, in order (Edit reorders them), each opening Edit
/// Space; New Space; the archived ones, each restored with one tap; and the profiles, each with the
/// Spaces using it, opening Edit Profile, and New Profile. Presented from the browser's root
/// (`BrowserStore.showManageSpaces()`).
struct ManageSpacesView: View {
    @Environment(BrowserStore.self) private var store
    @State private var editMode: EditMode = .inactive
    @State private var editing: Space?
    @State private var creating = false
    /// An archived Space swiped to Delete, waiting on its confirmation.
    @State private var deleting: Space?
    /// The dialog's title, kept after `deleting` clears so it doesn't go blank as the dialog leaves.
    @State private var deletingTitle = ""

    /// Pushed in Settings (Settings › Spaces) rather than presented on its own, with a Close button.
    var isPage = false

    var body: some View {
        if isPage {
            list
                .onAppear { store.isManagingSpacesInSettings = true }
                .onDisappear { store.isManagingSpacesInSettings = false }
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
        List {
            spacesSection
            archivedSection
            profilesSection
        }
        .environment(\.editMode, $editMode)
        // An archived Space swiped to Delete. On the list, not its section: from inside the section
        // the dialog took the sheet down with it.
        .confirmationDialog(deletingTitle, isPresented: isConfirmingDelete,
                            titleVisibility: .visible, presenting: deleting) { space in
            Button("Delete \(space.name)", role: .destructive) { store.deleteSpace(space.id) }
        } message: { space in
            Text(SpaceEditor.deleteMessage(tabCount: store.state.tabCount(inSpace: space.id)))
        }
        .navigationTitle("Spaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isPage {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { store.dismissManageSpaces() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .disabled(!editMode.isEditing && store.state.switchableSpaces.count < 2)
            }
        }
        .onAppear {
            // Asked for with a Space to edit (a strip icon's Edit): straight into its Edit Space.
            if !isPage, let id = store.spaceToEdit {
                store.spaceToEdit = nil
                editing = store.state.space(id)
            }
        }
        .sheet(item: $editing) { space in
            SpaceEditor(editing: space)
        }
        .sheet(isPresented: $creating) {
            SpaceEditor(newWith: store.state.suggestedNewSpaceLook)
        }
    }

    private var spacesSection: some View {
        Section {
            ForEach(store.state.switchableSpaces) { space in
                // Not `disabled` while reordering, which would dim the rows being dragged.
                Button { if !editMode.isEditing { editing = space } } label: {
                    HStack {
                        SpaceRow(space: space, detail: spaceDetail(space),
                                 isCurrent: space.id == store.state.activeSpaceID)
                        if !editMode.isEditing {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(editMode.isEditing ? "" : "Edits the Space")
            }
            .onMove(perform: move)
            if !editMode.isEditing {
                Button { creating = true } label: {
                    Label("New Space", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        let archived = store.state.archivedSpaces
        if !archived.isEmpty {
            Section("Archived") {
                ForEach(archived) { space in
                    HStack {
                        SpaceRow(space: space, detail: archivedDetail(space))
                        Button("Restore") { store.restoreSpace(space.id) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Restore \(space.name)")
                    }
                    // Deleted from here without restoring it first; confirmed, as in Edit Space.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Not `.destructive`: that role removes the row before the confirmation.
                        Button("Delete", systemImage: "trash") { confirmDelete(space) }
                            .tint(.red)
                    }
                    .accessibilityAction(named: "Delete \(space.name)") { confirmDelete(space) }
                }
            }
        }
    }

    /// Pushed pages, in Settings' stack or Manage Spaces' own alike.
    private var profilesSection: some View {
        Section {
            ForEach(store.state.profilesInOrder) { profile in
                NavigationLink {
                    ProfileEditor(editing: profile)
                } label: {
                    ProfileRow(profile: profile, detail: store.state.spaceNames(usingProfile: profile.id) ?? "No Spaces")
                }
                .accessibilityIdentifier("ProfileRow")
            }
            if !editMode.isEditing {
                NavigationLink {
                    ProfileEditor(newWith: store.state.suggestedNewProfileColor)
                } label: {
                    Label("New Profile", systemImage: "plus")
                        .foregroundStyle(Color.accentColor)
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Profiles keep logins and website data apart. A Space uses one profile; several Spaces can share it.")
        }
    }

    private func confirmDelete(_ space: Space) {
        deletingTitle = "Delete \(space.name)?"
        deleting = space
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func tabsPhrase(_ space: Space) -> String {
        let count = store.state.tabCount(inSpace: space.id)
        return count == 1 ? "1 tab" : "\(count) tabs"
    }

    /// Its tabs, then its profile where it isn't the default: "1 tab · Vialumi".
    private func spaceDetail(_ space: Space) -> String {
        let profile = store.state.profile(forSpace: space.id)
        return profile.isDefault ? tabsPhrase(space) : "\(tabsPhrase(space)) · \(profile.name)"
    }

    private func archivedDetail(_ space: Space) -> String {
        guard let archivedAt = space.archivedAt else { return tabsPhrase(space) }
        let sameYear = Calendar.current.isDate(archivedAt, equalTo: .now, toGranularity: .year)
        let date = sameYear ? archivedAt.formatted(.dateTime.month(.abbreviated).day())
            : archivedAt.formatted(.dateTime.month(.abbreviated).day().year())
        return "Archived \(date) · \(tabsPhrase(space))"
    }

    /// List offsets are among the switchable Spaces; archived ones keep their places between them.
    private func move(from source: IndexSet, to destination: Int) {
        let spaces = store.state.switchableSpaces
        let before = destination < spaces.count ? spaces[destination].id : nil
        for index in source { store.moveSpace(spaces[index].id, before: before) }
    }
}

/// A Space's badge, name and one line about it.
private struct SpaceRow: View {
    let space: Space
    let detail: String
    /// The Space you're in: checked.
    var isCurrent = false

    var body: some View {
        HStack(spacing: 14) {
            SpaceIconBadge(icon: space.icon, color: space.color, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(space.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityValue("\(space.icon.name) icon, \(space.color.name), \(detail)")
    }
}
