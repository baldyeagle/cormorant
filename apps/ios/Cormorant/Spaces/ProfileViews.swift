import CormorantCore
import SwiftUI

/// A profile's monogram: the first letter of its name, white on a circle of its color. Always a
/// circle, where a Space's icon is a rounded square, so the two never look alike.
struct ProfileMonogram: View {
    let monogram: String
    let color: Swatch
    var side: CGFloat = 32

    init(_ profile: Profile, side: CGFloat = 32) {
        self.init(monogram: profile.monogram, color: profile.color, side: side)
    }

    init(monogram: String, color: Swatch, side: CGFloat = 32) {
        self.monogram = monogram
        self.color = color
        self.side = side
    }

    var body: some View {
        Text(monogram)
            .font(.system(size: side * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.color, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A profile's monogram, name and one line about it, as Manage Spaces and the profile picker list it.
struct ProfileRow: View {
    let profile: Profile
    let detail: String
    var isChosen = false
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 34

    var body: some View {
        HStack(spacing: 14) {
            ProfileMonogram(profile, side: min(side, 48))
            VStack(alignment: .leading, spacing: 2) {
                // Colors, not the hierarchical styles: in a list's button those take the tint.
                Text(profile.name)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if isChosen {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.name)
        .accessibilityValue("\(profile.color.name), \(detail)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

extension BrowserState {
    /// The Spaces using the profile, by name, as a list: "Home, Projects and Trip".
    func spaceNames(usingProfile profileID: UUID, except spaceID: UUID? = nil) -> String? {
        let names = spaces(usingProfile: profileID).filter { $0.id != spaceID }.map(\.name)
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }
}

/// What a profile holds, for the profile picker and New Profile.
private let profileExplanation = "A profile keeps its own logins, cookies and website data. Spaces on the same profile share them; Spaces on different profiles can be signed in to different accounts on the same site."

// MARK: - Choosing a Space's profile

/// The profile a Space uses, from New and Edit Space: every profile, the chosen one checked, and New
/// Profile. Choosing doesn't go back, as Settings' choice lists don't. In Edit Space, a profile other
/// than the saved one is confirmed first when the Space has tabs: each reloads, signed out of the old
/// profile's accounts. Nothing changes until Edit Space's checkmark.
struct ProfilePicker: View {
    @Environment(BrowserStore.self) private var store
    @Binding var profileID: UUID
    /// The Space as it is in its editor: its name, and for Edit Space its saved profile and tab count.
    let spaceName: String
    /// Nil for New Space.
    let saved: Space?
    let tabCount: Int
    /// Waiting on the switch confirmation.
    @State private var switching: Profile?
    /// The dialog's title, kept after `switching` clears so it doesn't go blank as the dialog leaves.
    @State private var switchingTitle = ""
    /// Made from New Profile here, to choose once this page is back on top.
    @State private var created: Profile?

    var body: some View {
        List {
            Section {
                ForEach(store.state.profilesInOrder) { profile in
                    Button { choose(profile) } label: {
                        ProfileRow(profile: profile, detail: detail(profile), isChosen: profile.id == profileID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ProfileChoice")
                }
                NavigationLink {
                    ProfileEditor(newFor: spaceName, isNewSpace: saved == nil) { created = $0 }
                } label: {
                    Label("New Profile…", systemImage: "plus")
                        .foregroundStyle(Color.accentColor)
                }
            } footer: {
                if let saved, tabCount > 0 {
                    Text("Switching profiles reloads \(saved.name)'s tabs, signed in with the other profile's accounts.")
                } else {
                    Text(profileExplanation)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        // Back from New Profile with one made: chosen, confirmed as any other.
        .onAppear {
            guard let profile = created else { return }
            created = nil
            choose(profile)
        }
        .alert(switchingTitle, isPresented: isConfirming, presenting: switching) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Switch") { profileID = profile.id }
        } message: { profile in
            Text(switchMessage(to: profile))
        }
    }

    private func choose(_ profile: Profile) {
        guard profile.id != profileID else { return }
        // Back to the saved one, or nothing loaded under the old one: nothing to warn about.
        guard let saved, profile.id != saved.profileID, tabCount > 0 else {
            profileID = profile.id
            return
        }
        switchingTitle = "Switch \(saved.name) to \(profile.name)?"
        switching = profile
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })
    }

    private func switchMessage(to profile: Profile) -> String {
        guard let saved else { return "" }
        let tabs = tabCount == 1 ? "\(saved.name)'s tab reloads" : "\(saved.name)'s \(tabCount) tabs reload"
        let old = store.state.profile(saved.profileID)?.name ?? "the old profile"
        return "\(tabs) with \(profile.name)'s logins and cookies. Nothing in \(old) is deleted."
    }

    private func detail(_ profile: Profile) -> String {
        store.state.spaceNames(usingProfile: profile.id).map { "Used by \($0)" } ?? "Not used by any Space"
    }
}

// MARK: - New and Edit Profile

/// New Profile and Edit Profile, pushed: from Manage Spaces' Profiles section, and New Profile from the
/// profile picker. New Profile adds the profile at its checkmark. Edit Profile saves as you go, as
/// Settings' pages do: name and color, the Spaces using it, how many sites keep data in it, Clear
/// Website Data, and Delete Profile (not the default profile), each confirmed.
struct ProfileEditor: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Nil for New Profile.
    private let profileID: UUID?
    @State private var name: String
    @State private var color: Swatch
    @FocusState private var nameFocused: Bool
    /// New Profile from a Space's profile picker: the Space's name, and whether it's being made.
    private let forSpace: (name: String, isNew: Bool)?
    private let onCreated: (Profile) -> Void
    /// Sites keeping data in the profile; nil until WebKit says.
    @State private var siteCount: Int?
    @State private var isClearing = false
    @State private var confirmingClear = false
    @State private var confirmingDelete = false

    /// Edit Profile.
    init(editing profile: Profile) {
        profileID = profile.id
        _name = State(initialValue: profile.name)
        _color = State(initialValue: profile.color)
        forSpace = nil
        onCreated = { _ in }
    }

    /// New Profile, from Manage Spaces.
    init(newWith color: Swatch) {
        profileID = nil
        _name = State(initialValue: "")
        _color = State(initialValue: color)
        forSpace = nil
        onCreated = { _ in }
    }

    /// New Profile, from the profile picker of `spaceName`, which the new profile is for. Its color is
    /// the store's suggestion, set on appear.
    init(newFor spaceName: String, isNewSpace: Bool, onCreated: @escaping (Profile) -> Void) {
        profileID = nil
        _name = State(initialValue: "")
        _color = State(initialValue: .teal)
        forSpace = (spaceName, isNewSpace)
        self.onCreated = onCreated
    }

    private var isNew: Bool { profileID == nil }
    private var saved: Profile? { profileID.flatMap { store.state.profile($0) } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The name as it is in the field, or as saved while the field is blank.
    private var shownName: String { trimmedName.isEmpty ? (saved?.name ?? "") : trimmedName }
    private var monogram: String {
        Profile(id: profileID ?? UUID(), name: trimmedName.isEmpty ? (saved?.name ?? "") : trimmedName).monogram
    }

    var body: some View {
        Form {
            Section {
                ProfileMonogram(monogram: isNew && trimmedName.isEmpty ? "?" : monogram, color: color, side: 76)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: color)
                    .accessibilityElement()
                    .accessibilityLabel("Monogram")
                    .accessibilityIdentifier("Monogram")
                    .accessibilityValue("\(monogram), \(color.name)")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))

            Section("Name") {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("ProfileName")
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { nameFocused = false }
            }

            Section {
                SpaceColorPicker(color: $color)
            } header: {
                Text("Color")
            } footer: {
                if isNew {
                    Text("\(trimmedName.isEmpty ? "A new profile" : trimmedName) starts signed out of every site. Passwords and passkeys from the Passwords app still fill in.")
                }
            }

            if let forSpace {
                newProfileUsedBy(forSpace)
            } else if let saved {
                usedBySection(saved)
                websiteDataSection(saved)
                if !saved.isDefault { deleteSection(saved) }
            }
        }
        .navigationTitle(isNew ? "New Profile" : shownName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark", role: .confirm, action: create)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .onAppear {
            if isNew {
                if forSpace != nil { color = store.state.suggestedNewProfileColor }
                nameFocused = true
            }
        }
        // Saved as you go, a blank name keeping the old one.
        .onChange(of: name) { save() }
        .onChange(of: color) { save() }
        .task(id: profileID) { await countSites() }
        // Deleted, here or elsewhere.
        .onChange(of: saved == nil) { _, gone in if gone, !isNew { dismiss() } }
    }

    // MARK: New Profile

    private func newProfileUsedBy(_ space: (name: String, isNew: Bool)) -> some View {
        Section("Used by") {
            VStack(alignment: .leading, spacing: 2) {
                Text(space.name.isEmpty ? "New Space" : space.name)
                Text(space.isNew ? "The Space you're creating" : "The Space you're editing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    private func create() {
        guard let profile = store.createProfile(name: trimmedName, color: color) else { return }
        onCreated(profile)
        dismiss()
    }

    // MARK: Edit Profile

    private func usedBySection(_ profile: Profile) -> some View {
        let spaces = store.state.spaces(usingProfile: profile.id)
        return Section("Used by") {
            if spaces.isEmpty {
                Text("No Spaces use this profile.")
                    .foregroundStyle(.secondary)
            }
            ForEach(spaces) { space in
                HStack(spacing: 14) {
                    SpaceIconBadge(icon: space.icon, color: space.color, side: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name)
                        Text(usedByDetail(space))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ProfileSpace")
            }
        }
    }

    private func usedByDetail(_ space: Space) -> String {
        let count = store.state.tabCount(inSpace: space.id)
        let tabs = count == 1 ? "1 tab" : "\(count) tabs"
        return space.isArchived ? "Archived · \(tabs)" : tabs
    }

    private func websiteDataSection(_ profile: Profile) -> some View {
        Section {
            LabeledContent {
                if let siteCount {
                    Text(siteCount == 0 ? "None" : "\(siteCount)")
                } else {
                    ProgressView()
                }
            } label: {
                Label("Sites with Data", systemImage: "globe")
            }
            .accessibilityIdentifier("SitesWithData")
            Button("Clear Website Data…", systemImage: "trash") { confirmingClear = true }
                .disabled(isClearing)
                .confirmationDialog("Clear \(shownName)'s website data?", isPresented: $confirmingClear,
                                    titleVisibility: .visible) {
                    Button("Clear Website Data", role: .destructive) { clear(profile) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll be signed out of every site in \(shownName), and its cookies and website data are erased. Its open tabs reload. History is kept.")
                }
        } header: {
            Text("Website Data")
        } footer: {
            if profile.isDefault {
                Text("\(shownName) can be renamed, not deleted.")
            }
        }
    }

    private func deleteSection(_ profile: Profile) -> some View {
        Section {
            Button("Delete Profile", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .foregroundStyle(.red)
                .alert("Delete \(shownName)?", isPresented: $confirmingDelete) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { delete(profile) }
                } message: {
                    Text(deleteMessage(profile))
                }
        } footer: {
            Text(deleteFooter(profile))
        }
    }

    private var defaultName: String { store.state.profile(Profile.defaultID)?.name ?? "Default" }

    private func deleteFooter(_ profile: Profile) -> String {
        let erased = "Deleting signs you out of every site in \(shownName) and erases its cookies, website data and history."
        guard let spaces = store.state.spaceNames(usingProfile: profile.id) else { return erased }
        return "\(erased) \(spaces) \(switchVerb(profile)) to \(defaultName)."
    }

    private func deleteMessage(_ profile: Profile) -> String {
        let erased = "You'll be signed out of every site in this profile, and its cookies, website data and history are erased."
        let spaces = store.state.spaceNames(usingProfile: profile.id)
            .map { " \($0) \(switchVerb(profile)) to \(defaultName) and \(reloadVerb(profile))." } ?? ""
        return "\(erased)\(spaces) This can't be undone."
    }

    private func switchVerb(_ profile: Profile) -> String {
        store.state.spaces(usingProfile: profile.id).count == 1 ? "switches" : "switch"
    }

    private func reloadVerb(_ profile: Profile) -> String {
        store.state.spaces(usingProfile: profile.id).count == 1 ? "reloads" : "reload"
    }

    private func save() {
        guard let profileID else { return }
        store.updateProfile(profileID, name: name, color: color)
    }

    private func countSites() async {
        guard let profileID else { return }
        siteCount = await store.websiteDataSiteCount(of: profileID)
    }

    private func clear(_ profile: Profile) {
        isClearing = true
        Task {
            await store.clearWebsiteData(of: profile.id)
            isClearing = false
            await countSites()
        }
    }

    /// The page goes back once the profile is gone (`onChange` of `saved`): dismissing here too would
    /// take a second step back, closing Settings under Manage Spaces.
    private func delete(_ profile: Profile) {
        store.deleteProfile(profile.id)
    }
}
