import AppKit
import CormorantBrowser
import CormorantCore
import SwiftUI

/// ⌘T's new tab, centered over the page, or ⌘L's edit of this tab's address, out of the sidebar:
/// a field with what it would open listed under it, ↑↓ to choose, ↩ to open, ⌘↩ in the background.
struct CommandBar: View {
    enum Mode {
        case newTab
        case editAddress
    }

    let mode: Mode
    let store: BrowserStore
    let dismiss: () -> Void

    @State private var text = ""
    @State private var initialText = ""
    @State private var selection: TextSelection?
    @State private var completion: InlineCompletion?
    @State private var completionHosts: [String] = []
    @State private var lookup = AddressPanel.Lookup()
    /// This site's pages, for ⌘L before anything's typed.
    @State private var sitePages: [HistoryEntry] = []
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let sections = self.sections
        let rows = sections.flatMap(\.rows)
        VStack(spacing: 0) {
            field(rows: rows)
            if !rows.isEmpty {
                Divider().opacity(0.5)
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                if let title = section.title {
                                    Text(title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 18)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                }
                                ForEach(section.rows) { row in
                                    let index = rows.firstIndex { $0.id == row.id } ?? 0
                                    rowView(row, isSelected: index == selectedIndex)
                                        .id(row.id)
                                        .onTapGesture { open(row, inBackground: NSEvent.modifierFlags.contains(.command)) }
                                        .onHover { if $0 { selectedIndex = index } }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selectedIndex) { _, index in
                        if rows.indices.contains(index) { scroller.scrollTo(rows[index].id) }
                    }
                }
            }
            Divider().opacity(0.5)
            footer
        }
        // Nearly opaque, so whatever page is under it never sets its color; the blur only softens.
        .background {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.25), radius: 40, y: 15)
        .onAppear(perform: start)
        .onChange(of: store.addressFocusRequest) { fieldFocused = true }
        .onChange(of: text) { old, new in textDidChange(from: old, to: new) }
        .onChange(of: query) { selectedIndex = firstSelection }
        .task { completionHosts = await store.browsingHistory?.completionHosts(profile: store.activeProfileID) ?? [] }
        .task(id: query) { await lookUp() }
    }

    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.129).opacity(0.94)
            : Color(red: 0.988, green: 0.988, blue: 0.992).opacity(0.94)
    }

    // MARK: Field

    private func field(rows: [Row]) -> some View {
        HStack(spacing: 12) {
            if mode == .newTab {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            TextField(mode == .newTab ? "Search or enter address" : "Address", text: $text, selection: $selection)
                .textFieldStyle(.plain)
                .font(.system(size: mode == .newTab ? 22 : 15))
                .focused($fieldFocused)
                .onKeyPress(.downArrow) {
                    selectedIndex = min(selectedIndex + 1, rows.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedIndex = max(selectedIndex - 1, firstSelection)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if rows.indices.contains(selectedIndex) {
                        open(rows[selectedIndex], inBackground: press.modifiers.contains(.command))
                    } else {
                        store.submit(text)
                        dismiss()
                    }
                    return .handled
                }
                .onExitCommand(perform: dismiss)
        }
        .padding(.horizontal, 18)
        .frame(height: mode == .newTab ? 60 : 48)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            switch mode {
            case .newTab:
                hint("↩", "Open")
                hint("⌘↩", "Background tab")
                Spacer()
                Text("Searching with \(store.settings.searchEngine.name)")
                    .foregroundStyle(.secondary)
            case .editAddress:
                hint("⇧⌘C", "Copy Link")
                hint("esc", "Cancel")
                Spacer()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .frame(height: 40)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 20)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 5))
            Text(label)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    enum Row: Identifiable {
        case open(URL)
        case pasteAndGo
        case tab(CormorantCore.Tab)
        case page(HistoryEntry)
        case closed(ArchivedTab)
        case search(SearchSuggestion)

        var id: String {
            switch self {
            case .open(let url): "open:\(url.absoluteString)"
            case .pasteAndGo: "paste"
            case .tab(let tab): "tab:\(tab.id)"
            case .page(let entry): "page:\(entry.key)"
            case .closed(let entry): "closed:\(entry.id)"
            case .search(let suggestion): "search:\(suggestion.query)"
            }
        }
    }

    struct Section: Identifiable {
        let title: String?
        let rows: [Row]
        var id: String { title ?? "top" }
    }

    private var sections: [Section] {
        if mode == .editAddress, query == nil {
            let paste = NSPasteboard.general.availableType(from: [.URL, .string]) == nil ? [] : [Row.pasteAndGo]
            let host = store.activeTab?.url?.host().map { $0.replacing(/^www\./, with: "") }
            let here = store.activeTab?.url.flatMap(BrowsingHistory.key(for:))
            let site = sitePages.filter { $0.key != here }.prefix(6).map(Row.page)
            return [Section(title: nil, rows: paste), Section(title: host, rows: Array(site))].filter { !$0.rows.isEmpty }
        }
        let shown = AddressPanel.shown(for: query, lookup: lookup, in: store, tabsFromEverySpace: true)
        var top: [Row] = []
        var tabs = shown.pins + shown.openTabs
        var searches = shown.searches
        // What the text itself does comes first, so ↩ always does it.
        switch query == nil ? nil : AddressResolver.resolve(text, engine: store.settings.searchEngine) {
        case .navigate(let url):
            // A tab already there, to switch to rather than open the page again.
            if let tab = AddressPanel.openTab(on: url, in: store, tabsFromEverySpace: true) {
                top = [.tab(tab)]
                tabs.removeAll { $0.id == tab.id }
            } else {
                top = [.open(url)]
            }
        case .search:
            if let typed = searches.first(where: { $0.source == .typed }) {
                top = [.search(typed)]
                searches.removeAll { $0 == typed }
            }
        case nil:
            break
        }
        return [
            Section(title: nil, rows: top),
            Section(title: "Tabs", rows: tabs.map(Row.tab)),
            Section(title: "History", rows: shown.pages.map(Row.page)),
            Section(title: "Recently closed", rows: shown.closed.map(Row.closed)),
            Section(title: "Search", rows: searches.map(Row.search)),
        ].filter { !$0.rows.isEmpty }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            icon(for: row)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            label(for: row)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing(for: row, isSelected: isSelected)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(isSelected ? store.state.activeSpace.color.color.opacity(colorScheme == .dark ? 0.3 : 0.18) : .clear,
                    in: .rect(cornerRadius: 9))
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(for row: Row) -> some View {
        switch row {
        case .open: Image(systemName: "globe").foregroundStyle(.secondary)
        case .pasteAndGo: Image(systemName: "arrow.right").foregroundStyle(.secondary)
        case .tab(let tab): favicon(tab.url)
        case .page: Image(systemName: "clock").foregroundStyle(.secondary)
        case .closed: Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
        case .search: Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func favicon(_ url: URL?) -> some View {
        if let image = store.favicons.icon(for: url, pixels: Int((18 * displayScale).rounded())) {
            Image(decorative: image, scale: displayScale).resizable().frame(width: 18, height: 18).clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: "globe").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func label(for row: Row) -> some View {
        switch row {
        case .open(let url):
            Text(Self.shortAddress(url)).fontWeight(.semibold)
        case .pasteAndGo:
            Text("Paste and Go")
        case .tab(let tab):
            titled(tab.displayTitle, tab.url.map(Self.shortAddress))
        case .page(let entry):
            titled(entry.displayTitle, Self.shortAddress(entry.url))
        case .closed(let entry):
            titled(entry.displayTitle, Self.shortAddress(entry.url))
        case .search(let suggestion):
            Text(suggestion.query)
        }
    }

    private func titled(_ title: String, _ address: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
            if let address, address != title {
                Text(address).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func trailing(for row: Row, isSelected: Bool) -> some View {
        switch row {
        case .tab(let tab) where tab.spaceID != store.state.activeSpaceID:
            if let space = store.state.space(tab.spaceID) {
                HStack(spacing: 6) {
                    SpaceBadge(space: space, side: 18)
                    Text("in \(space.name)")
                }
                .foregroundStyle(.secondary)
            }
        case .tab(let tab) where tab.id != store.state.activeTabID:
            Text("Switch to Tab").foregroundStyle(.secondary)
        case .pasteAndGo:
            Text("⇧⌘V").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        default:
            if isSelected { Text("↩").foregroundStyle(.secondary) }
        }
    }

    /// The address without its scheme, `www.` or a lone trailing slash, as the sidebar shows hosts.
    static func shortAddress(_ url: URL) -> String {
        var address = url.absoluteString
        for prefix in ["https://", "http://"] where address.hasPrefix(prefix) { address.removeFirst(prefix.count) }
        if address.hasPrefix("www.") { address.removeFirst(4) }
        if address.hasSuffix("/"), address.dropLast().contains("/") == false { address.removeLast() }
        return address
    }

    // MARK: Typing

    /// The typed text, without any completion, once the user has typed; nil for the untouched address.
    private var query: String? {
        let typed = completion?.typed ?? text
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || typed == initialText ? nil : trimmed
    }

    /// ⌘L before anything's typed has no row chosen, so ↩ goes to the address in the field.
    private var firstSelection: Int { mode == .editAddress && query == nil ? -1 : 0 }

    private func start() {
        if mode == .editAddress {
            text = store.activeTab?.url?.absoluteString ?? ""
            initialText = text
        }
        selectedIndex = firstSelection
        fieldFocused = true
        // After the field has the text, or setting it moves the caret to the end.
        Task { selection = text.isEmpty ? nil : TextSelection(range: text.startIndex..<text.endIndex) }
    }

    private func lookUp() async {
        guard !store.searchesPrivately else { return }
        guard let query else {
            lookup = AddressPanel.Lookup()
            if mode == .editAddress, let host = store.activeTab?.url?.host() {
                sitePages = await AddressPanel.historyLookup(for: host, in: store).pages
            }
            return
        }
        await AddressPanel.lookUp(query, after: lookup, in: store) { lookup = $0 }
    }

    /// Completes the field to a visited site while typing at its end; never on a deletion, so
    /// backspace takes the completion away and leaves it away. As the iPhone's search panel does.
    private func textDidChange(from old: String, to new: String) {
        if let completion, new == completion.text { return }
        let previous = completion
        completion = nil
        // The first key over the selected address replaces all of it, even its own first letter.
        let replacesAddress = old == initialText && new.count == 1
        let isDeletion: Bool
        if let previous {
            // Backspace over the selected completion leaves what was typed; backspace after it was
            // accepted leaves all but its last letter, told from typing its next letter by length.
            isDeletion = previous.typed.hasPrefix(new)
                || (previous.text.hasPrefix(new) && new.count == previous.text.count - 1
                    && new.count != previous.typed.count + 1)
        } else {
            isDeletion = old.hasPrefix(new) && new.count < old.count && !replacesAddress
        }
        guard !isDeletion, !store.searchesPrivately, new != initialText, new.allSatisfy(\.isASCII),
              previous != nil || replacesAddress || caretIsAtEnd(of: new),
              let found = InlineCompletion(completing: new, from: completionHosts) else { return }
        completion = found
        text = found.text
        let start = found.text.index(found.text.startIndex, offsetBy: found.typed.count)
        selection = TextSelection(range: start..<found.text.endIndex)
    }

    /// No selection known, or a caret at the end of `text` (the selection can lag it by a key).
    private func caretIsAtEnd(of text: String) -> Bool {
        guard !text.isEmpty, case .selection(let range)? = selection?.indices else { return true }
        return range.isEmpty && range.lowerBound >= text.index(before: text.endIndex)
    }

    // MARK: Opening

    private func open(_ row: Row, inBackground: Bool) {
        switch row {
        case .open(let url):
            if inBackground {
                openInBackground(url)
            } else {
                store.submit(text)
            }
        case .pasteAndGo:
            if let pasted = NSPasteboard.general.string(forType: .string) { store.submit(pasted) }
        case .tab(let tab):
            store.activate(tab.id)
        case .page(let entry):
            if inBackground { openInBackground(entry.url) } else { store.open(historyPage: entry.url) }
        case .closed(let entry):
            store.restore(entry.id)
        case .search(let suggestion):
            if inBackground, let url = store.settings.searchEngine.url(for: suggestion.query) {
                openInBackground(url)
            } else {
                store.search(suggestion.query)
            }
        }
        dismiss()
    }

    private func openInBackground(_ url: URL) {
        _ = store.openLink(url, inBackground: true, inSpace: nil, from: nil, handoff: nil)
    }
}
