import CormorantBrowser
import CormorantCore
import SwiftUI

extension Folder {
    /// What it's drawn with: its icon, or a plain folder.
    var symbol: String { icon ?? "folder.fill" }
}

/// Something about a folder that needs more than a tap: a name for a new one, a new name, an icon.
enum FolderPrompt: Identifiable, Equatable {
    case newFolder(tabID: UUID)
    case rename(folderID: UUID)
    case icon(folderID: UUID)

    var id: String {
        switch self {
        case .newFolder(let id): "new-\(id)"
        case .rename(let id): "rename-\(id)"
        case .icon(let id): "icon-\(id)"
        }
    }
}

/// The alerts and the sheet a `FolderPrompt` asks for.
struct FolderPrompts: ViewModifier {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var prompt: FolderPrompt?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(alertTitle, isPresented: isAsking) {
                TextField(Folder.defaultName, text: $name)
                Button(isNaming ? "Create" : "Save") { save() }
                Button("Cancel", role: .cancel) { prompt = nil }
            }
            .sheet(item: iconFolder) { request in
                FolderIconPicker(folderID: request.folderID)
            }
            .onChange(of: prompt) { _, prompt in
                if case .rename(let folderID) = prompt {
                    name = store.state.folder(folderID)?.name ?? ""
                } else {
                    name = ""
                }
            }
    }

    private var isNaming: Bool {
        if case .newFolder = prompt { true } else { false }
    }

    private var alertTitle: String { isNaming ? "New Folder" : "Rename Folder" }

    private var isAsking: Binding<Bool> {
        Binding(get: {
            switch prompt {
            case .newFolder, .rename: true
            default: false
            }
        }, set: { if !$0 { prompt = nil } })
    }

    private var iconFolder: Binding<IconRequest?> {
        Binding(get: {
            if case .icon(let folderID) = prompt { IconRequest(folderID: folderID) } else { nil }
        }, set: { if $0 == nil, case .icon = prompt { prompt = nil } })
    }

    private func save() {
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)
        switch prompt {
        case .newFolder(let tabID):
            withAnimation(animation) { _ = store.newFolder(with: tabID, name: name) }
        case .rename(let folderID):
            store.renameFolder(folderID, to: name)
        default: break
        }
        prompt = nil
    }

    private struct IconRequest: Identifiable {
        let folderID: UUID
        var id: UUID { folderID }
    }
}

/// "Add to Folder": the folders the tab can join, then New Folder…, which asks for a name.
struct AddToFolderMenu: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tabID: UUID
    let onPrompt: (FolderPrompt) -> Void

    var body: some View {
        Menu {
            ForEach(store.folders(for: tabID)) { folder in
                Button(folder.name, systemImage: folder.symbol) {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) {
                        store.addToFolder(tabID, folder.id)
                    }
                }
            }
            Section {
                Button("New Folder…", systemImage: "folder.badge.plus") { onPrompt(.newFolder(tabID: tabID)) }
            }
        } label: {
            Label("Add to Folder", systemImage: "folder")
        }
    }
}

/// A folder's menu, on its card, its tile and its panel's ⋯: Rename, Icon, Pin or Unpin, Ungroup, Close.
struct FolderMenu: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let folder: Folder
    let isPinned: Bool
    let onPrompt: (FolderPrompt) -> Void

    var body: some View {
        Button("Rename…", systemImage: "pencil") { onPrompt(.rename(folderID: folder.id)) }
        Button("Icon…", systemImage: "square.grid.2x2") { onPrompt(.icon(folderID: folder.id)) }
        Button(isPinned ? "Unpin Folder" : "Pin Folder", systemImage: isPinned ? "pin.slash" : "pin") {
            animate { store.moveFolder(folder.id, toPinned: !isPinned) }
        }
        Button("Ungroup", systemImage: "folder.badge.minus") { animate { store.ungroupFolder(folder.id) } }
        Section {
            Button("Close Folder", systemImage: "xmark", role: .destructive) { animate { store.closeFolder(folder.id) } }
        }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25), change)
    }
}

/// A pinned folder in the switcher's row of tiles: its symbol large, in the Space's color, on a light
/// fill of it, its name under it. Ringed while one of its tabs is on screen.
struct FolderTile: View {
    let folder: Folder
    let isActive: Bool
    let accent: Color
    @ScaledMetric(relativeTo: .caption) private var scaledSide: CGFloat = 60

    private var side: CGFloat { min(scaledSide, 84) }
    private var radius: CGFloat { side * 0.28 }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: folder.symbol)
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: side, height: side)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(accent.opacity(0.14))
                        }
                }
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                            .strokeBorder(accent, lineWidth: 2.5)
                            .padding(-4)
                    }
                }
            Text(folder.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: side + 10)
        }
        .contentShape(.rect)
    }
}

/// A folder among the switcher's cards: its most recent tab's card in front of two peeking out behind,
/// the folder's symbol and name above, a few favicons and its count below. Laid out as a `TabCard` is.
struct FolderCard: View {
    let folder: Folder
    /// Most recently viewed first.
    let tabs: [CormorantCore.Tab]
    let snapshot: CGImage?
    let favicons: FaviconStore
    let isActive: Bool
    var accent: Color = .accentColor
    let size: CGSize
    let labelWidth: CGFloat
    let onOpen: () -> Void

    /// How far each card behind shows above the one in front of it.
    private static let peek: CGFloat = 9

    private var front: CormorantCore.Tab? { tabs.first }
    private var host: String { front?.url?.displayHost ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            stack
        }
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folder.name)
        .accessibilityValue(Self.count(tabs.count))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this folder’s tabs")
        .accessibilityAction { onOpen() }
        .accessibilityIdentifier("FolderCard")
    }

    static func count(_ count: Int) -> String { count == 1 ? "1 tab" : "\(count) tabs" }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
            Text(folder.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .frame(width: labelWidth, alignment: .leading)
        .padding(.leading, 2)
    }

    private var stack: some View {
        ZStack(alignment: .top) {
            behind(inset: 2)
            behind(inset: 1)
            card
                .padding(.top, 2 * Self.peek)
        }
        .frame(width: size.width, height: size.height)
    }

    /// A card behind the front one, `inset` steps narrower and higher.
    private func behind(inset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.07 * inset))
            }
            .frame(width: size.width - inset * 22, height: size.height - 2 * Self.peek)
            .padding(.top, (2 - inset) * Self.peek)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var card: some View {
        VStack(spacing: 0) {
            TabPreview(snapshot: snapshot, host: host, width: size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            footer
        }
        .frame(width: size.width, height: size.height - 2 * Self.peek)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isActive ? accent : .clear, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: -4) {
                ForEach(tabs.prefix(4)) { tab in
                    FaviconView(favicons: favicons, url: tab.url, host: tab.url?.displayHost ?? "", side: 18,
                                backsDarkIcons: true)
                        .padding(1.5)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 6, style: .continuous))
                }
            }
            Spacer(minLength: 0)
            Text(Self.count(tabs.count))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Above a folder's cards: back to all of them, and which folder this is.
struct FolderBackPill: View {
    let folder: Folder
    let accent: Color
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                Text("All Tabs")
                    .font(.subheadline.weight(.semibold))
                Text("·")
                    .foregroundStyle(.secondary)
                Image(systemName: folder.symbol)
                    .font(.subheadline)
                    .foregroundStyle(accent)
                Text(folder.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("All Tabs")
        .accessibilityValue("In \(folder.name)")
        .accessibilityHint("Shows all the Space’s tabs")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onBack() }
        .accessibilityIdentifier("FolderBackPill")
    }
}

/// A pinned folder opened from its tile, like a home-screen folder: its name and ⋯ menu over its tabs
/// as rows (their titles are long). Tap a row to open that tab.
struct FolderPanel: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let folder: Folder
    let tabs: [CormorantCore.Tab]
    let accent: Color
    /// The row's frame on screen, for the card that grows from it.
    let onOpen: (CormorantCore.Tab, CGRect) -> Void
    let onClose: (CormorantCore.Tab) -> Void
    let onPrompt: (FolderPrompt) -> Void
    let onDismiss: () -> Void
    @State private var frames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.bottom, 8)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityIdentifier("FolderPanel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(folder.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Menu {
                FolderMenu(folder: folder, isPinned: true, onPrompt: onPrompt)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: .circle)
            }
            .accessibilityLabel("Folder Actions")
            .accessibilityIdentifier("FolderPanelMenu")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: .circle)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("FolderPanelClose")
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(tabs) { row($0) }
        }
    }

    private func row(_ tab: CormorantCore.Tab) -> some View {
        let isActive = tab.id == store.state.activeTabID
        // As its tile would show it: the pinned page's.
        let url = tab.pinnedURL ?? tab.url
        return Button {
            onOpen(tab, frames[tab.id] ?? .zero)
        } label: {
            HStack(spacing: 12) {
                FaviconView(favicons: store.favicons, url: url, host: url?.displayHost ?? "", side: 28, backsDarkIcons: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.pinName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(url?.displayHost ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[tab.id] = $0 }
        .contextMenu {
            if tab.isAwayFromPin {
                Button("Back to Pinned Page", systemImage: "arrow.uturn.backward") { store.backToPinnedPage(tab.id) }
            }
            AddToFolderMenu(tabID: tab.id, onPrompt: onPrompt)
            Button("Remove from Folder", systemImage: "folder.badge.minus") { animate { store.removeFromFolder(tab.id) } }
            Button("Unpin", systemImage: "pin.slash") { animate { store.unpin(tab.id) } }
            Button("Close", systemImage: "xmark", role: .destructive) { onClose(tab) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.pinName)
        .accessibilityValue(tab.pinAccessibilityValue(isActive: isActive))
        .accessibilityHint("Opens this pinned tab")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(tab, frames[tab.id] ?? .zero) }
        .accessibilityActions {
            if tab.isAwayFromPin {
                Button("Back to Pinned Page") { store.backToPinnedPage(tab.id) }
            }
            Button("Remove from Folder") { animate { store.removeFromFolder(tab.id) } }
            Button("Unpin") { animate { store.unpin(tab.id) } }
            Button("Close") { onClose(tab) }
        }
        .accessibilityIdentifier("FolderPanelTab")
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25), change)
    }
}

/// The folder panel coming from its tile and going back to it: from the tile's place, small.
struct FolderPanelZoom: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}

/// A grid of `Folder.icons` and a plain folder, to draw on a folder.
struct FolderIconPicker: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let folderID: UUID

    var body: some View {
        let folder = store.state.folder(folderID)
        let accent = store.shownSpace?.color.color ?? .accentColor
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    plain(isChosen: folder?.icon == nil, accent: accent)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 12)], spacing: 12) {
                        ForEach(Folder.icons, id: \.self) { choice($0, current: folder?.icon, accent: accent) }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func plain(isChosen: Bool, accent: Color) -> some View {
        Button {
            store.setFolderIcon(folderID, nil)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(accent)
                Text("Plain Folder")
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(accent.opacity(isChosen ? 0.22 : 0.1), in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func choice(_ icon: String, current: String?, accent: Color) -> some View {
        let isChosen = icon == current
        return Button {
            store.setFolderIcon(folderID, icon)
            dismiss()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 52, height: 52)
                .background(accent.opacity(isChosen ? 0.22 : 0.1), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    if isChosen {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(accent, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.name(icon))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// A symbol's name as VoiceOver says it: "globe.americas.fill" as "Globe Americas".
    private static func name(_ symbol: String) -> String {
        if symbol == "chevron.left.forwardslash.chevron.right" { return "Code" }
        return symbol.split(separator: ".").filter { $0 != "fill" }.map { $0.capitalized }.joined(separator: " ")
    }
}
