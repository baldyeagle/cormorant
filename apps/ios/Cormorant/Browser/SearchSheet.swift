import CormorantCore
import SwiftUI

/// The search panel: an in-place overlay (not a `.sheet`) that rides on the keyboard, with the
/// full URL selected in the field (empty for a new tab) and suggestions below it, grouped by kind.
/// It holds a set height while you type (rows scroll inside it); its handle drags it up to fill the
/// space above the keyboard.
///
/// Untouched, it lists open tabs and recently closed ones. Typing completes the field to a visited
/// site (the rest selected, so the next key replaces it) and lists matching open tabs, history,
/// closed tabs and searches (the typed text, earlier searches, and the engine's suggestions).
/// Composing a new tab, the tab it came from is listed first, to edit its address. Opened with
/// Search Tabs, a Tabs token limits it to open tabs.
///
/// Closes on submit, on choosing a row, on a tap outside, on a swipe down, on Escape, and when
/// the keyboard goes away; the owner does that by watching `isFocused`.
struct SearchSheet: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL?
    var isFocused: FocusState<Bool>.Binding
    /// VoiceOver's cursor, moved to the field when the Edit row fills it (the row itself goes away).
    @AccessibilityFocusState private var fieldHasVoiceOver: Bool
    let onDismiss: () -> Void
    /// False over the empty state: there's no page to dim, so the launch screen's background stays put.
    var dimsPage = true
    /// The panel's top edge in global coordinates, so the empty state can keep its mark above it.
    var onPanelTopChange: (CGFloat) -> Void = { _ in }

    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var initialText = ""
    /// A suggestion `fill` put in the field, so the change isn't taken for typing and completed.
    @State private var filled: String?
    /// The handle's drag so far, down positive. Gesture state, so a drag the system cancels (the app
    /// leaving the foreground mid-drag) puts the panel back rather than leaving it pulled.
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragTranslation: CGFloat = 0
    /// Where a drag that closes the panel let go, so it leaves from there rather than springing back.
    @State private var releasedOffset: CGFloat = 0
    /// Dragged up to fill the space above the keyboard; otherwise about half of it.
    @State private var isExpanded = false
    /// Between the top of the safe area and the keyboard.
    @State private var availableHeight: CGFloat = 0
    /// The URL is selected once, when focus first lands; refocusing later keeps the user's caret.
    @State private var didSelectInitially = false
    /// The site the field completes the typed text to; its suffix is the selected end of `text`.
    @State private var completion: InlineCompletion?
    /// Visited sites, best first, to complete to. Read once, so a keystroke is completed in the same
    /// update that delivers it: anything slower can land after the field has taken the next key, and
    /// setting the text then would drop that key.
    @State private var completionHosts: [String] = []
    /// History and engine results, for `lookup.text`.
    @State private var lookup = Lookup()
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 18

    private static let rowLimit = 6
    private static let dismissDistance: CGFloat = 70
    /// Typing pauses this long before the engine is asked, so a quick word is one request, not five.
    private static let engineDelay: Duration = .milliseconds(150)

    private struct Lookup: Equatable {
        var text = ""
        var pages: [HistoryEntry] = []
        var pastSearches: [String] = []
        var engineSuggestions: [String] = []
    }

    /// What a lookup depends on; a change starts a new one.
    private struct LookupKey: Equatable {
        let query: String?
        let engine: SearchEngine
        let asksEngine: Bool
    }

    var body: some View {
        let shown = self.shown
        ZStack(alignment: .bottom) {
            scrim
            panel(shown)
                .offset(y: panelOffset(hasRows: !shown.isEmpty))
                // Outside the drag offset: where the panel rests, not where a finger holds it.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onPanelTopChange($0) }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .onAppear {
            text = url?.absoluteString ?? ""
            initialText = text
            isFocused.wrappedValue = true
        }
        // A selection set before the field is first responder is dropped, so select on focus.
        .onChange(of: isFocused.wrappedValue, initial: true) { _, focused in
            guard focused, !didSelectInitially else { return }
            didSelectInitially = true
            Task { selectAll() }
        }
        .onChange(of: text) { old, new in textDidChange(from: old, to: new) }
        .task { completionHosts = await store.browsingHistory?.completionHosts() ?? [] }
        .task(id: LookupKey(query: isTabSearch ? nil : query, engine: store.settings.searchEngine,
                            asksEngine: store.settings.searchSuggestions)) {
            await lookUp()
        }
    }

    private var isTabSearch: Bool { store.isSearchingTabs }

    // MARK: Chrome

    /// Dims the page; a tap anywhere on it closes the panel.
    private var scrim: some View {
        Color(white: 0, opacity: dimsPage ? 0.24 : 0)
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture(perform: onDismiss)
            .transition(.opacity)
            .accessibilityLabel("Close search")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onDismiss() }
    }

    /// A set height whatever it lists, so typing never resizes it: about half the space above the
    /// keyboard, or all of it once dragged up. Just the field when there's nothing to list.
    private func panel(_ shown: Shown) -> some View {
        VStack(spacing: 0) {
            grabber(hasRows: !shown.isEmpty)
            field
                .padding(.horizontal, 12)
                .layoutPriority(1)
            results(shown)
        }
        .padding(.bottom, 8)
        .frame(height: panelHeight(hasRows: !shown.isEmpty), alignment: .top)
        .frame(maxWidth: 640)
        // Tinted toward the background so titles stay legible over busy pages.
        .glassEffect(.regular.tint(Color(.systemBackground).opacity(0.4)),
                     in: .rect(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityAction(.escape) { onDismiss() }
    }

    /// Margins: 8 under the panel (above the keyboard), 8 over it when it's dragged all the way up.
    private var expandedHeight: CGFloat { max(0, availableHeight - 16) }
    private var restingHeight: CGFloat { min(expandedHeight, max(availableHeight * 0.55, fieldHeight * 4)) }

    /// Follows the handle between the two heights; nil (hugging the field) with no rows.
    private func panelHeight(hasRows: Bool) -> CGFloat? {
        guard hasRows, availableHeight > 0 else { return nil }
        let base = isExpanded ? expandedHeight : restingHeight
        return min(expandedHeight, max(restingHeight, base - dragTranslation))
    }

    /// How far the handle has pulled the panel down below its resting height, toward closing.
    private func panelOffset(hasRows: Bool) -> CGFloat {
        max(0, dragTranslation - slack(hasRows: hasRows)) + releasedOffset
    }

    /// How far the handle travels down before the panel itself moves: from all the way up to resting.
    private func slack(hasRows: Bool) -> CGFloat {
        hasRows && isExpanded ? expandedHeight - restingHeight : 0
    }

    /// The handle drags the panel up to fill the space above the keyboard, back down, and further
    /// down to close it. Only the handle, so dragging never fights text selection or scrolling.
    /// Measured in global space: the handle rides the offset it drives, so local translations
    /// would feed back and make the panel stutter between two positions.
    private func grabber(hasRows: Bool) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($dragTranslation) { value, translation, _ in translation = value.translation.height }
                    .onEnded { value in
                        let travel = slack(hasRows: hasRows)
                        // A fling down closes it from its resting height, not from all the way up.
                        if value.translation.height - travel > Self.dismissDistance
                            || (travel == 0 && value.predictedEndTranslation.height > Self.dismissDistance * 2) {
                            releasedOffset = max(0, value.translation.height - travel)
                            onDismiss()
                            return
                        }
                        guard hasRows else { return }
                        let base = isExpanded ? expandedHeight : restingHeight
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy) {
                            isExpanded = base - value.predictedEndTranslation.height > (restingHeight + expandedHeight) / 2
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(isExpanded ? "Show Fewer Results" : "Show More Results")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy) { isExpanded.toggle() }
            }
            .accessibilityHidden(!hasRows)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if isTabSearch { tabsToken }
            TextField(isTabSearch ? "Search open tabs" : "Search or enter address", text: $text, selection: $selection)
                .focused(isFocused)
                .keyboardType(.webSearch)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .accessibilityLabel(isTabSearch ? "Search open tabs" : "Search or enter address")
                .accessibilityFocused($fieldHasVoiceOver)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    text = ""
                    isFocused.wrappedValue = true
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(.rect)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(minHeight: fieldHeight)
        .background(.fill.tertiary, in: .capsule)
    }

    /// Says the field searches open tabs only; tapping it searches everything again.
    private var tabsToken: some View {
        Button {
            store.stopSearchingTabs()
            isFocused.wrappedValue = true
        } label: {
            HStack(spacing: 4) {
                Text("Tabs")
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(.brandCyanForeground))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.brandCyan), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Open tabs only")
        .accessibilityHint("Searches everything instead")
    }

    // MARK: Results

    /// The rows to show, by section.
    private struct Shown {
        /// Search Tabs only: how many tabs, and how many match.
        var tabsHeader = ""
        var openTabs: [CormorantCore.Tab] = []
        var pages: [HistoryEntry] = []
        var closed: [ArchivedTab] = []
        var searches: [SearchSuggestion] = []

        /// Nothing to list. Search Tabs always has its line, "0 matches" included.
        var isEmpty: Bool { tabsHeader.isEmpty && openTabs.isEmpty && pages.isEmpty && closed.isEmpty && searches.isEmpty }
    }

    @ViewBuilder
    private func results(_ shown: Shown) -> some View {
        if !shown.isEmpty {
            ScrollView {
                rows(shown)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 6)
        }
    }

    /// Open tabs, history, closed tabs, then searches, with a gap between kinds rather than a heading:
    /// the Switch pill, the time since closing and the search icon tell them apart.
    private func rows(_ shown: Shown) -> some View {
        VStack(spacing: 8) {
            if isTabSearch {
                SectionHeader(title: shown.tabsHeader)
            }
            if !shown.openTabs.isEmpty {
                VStack(spacing: 0) { ForEach(shown.openTabs) { tabRow($0) } }
            }
            if !shown.pages.isEmpty {
                VStack(spacing: 0) { ForEach(shown.pages, id: \.key) { pageRow($0) } }
            }
            if !shown.closed.isEmpty {
                VStack(spacing: 0) { ForEach(shown.closed) { closedRow($0) } }
            }
            if !shown.searches.isEmpty {
                VStack(spacing: 0) { ForEach(shown.searches, id: \.self) { searchRow($0) } }
            }
        }
        .padding(.horizontal, 12)
    }

    private var shown: Shown {
        if isTabSearch {
            let all = store.tabs.filter { $0.url != nil }
            guard let query else { return Shown(tabsHeader: Self.tabCount(all.count), openTabs: all) }
            let matching = all.filter { AddressSuggestions.matches(query, title: $0.displayTitle, url: $0.url) }
            let matches = matching.count == 1 ? "1 match" : "\(matching.count) matches"
            return Shown(tabsHeader: "\(Self.tabCount(all.count)) · \(matches)", openTabs: matching)
        }
        guard let query else {
            return Shown(openTabs: Array(tabCandidates.prefix(Self.rowLimit)),
                         closed: Array(recentlyClosed.prefix(Self.rowLimit)))
        }
        // Until this query's own results arrive, the last ones that still fit it stand in, so rows
        // don't blink out and back on every key.
        let current = lookup.text == query
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let suggestions = AddressSuggestions(
            text: query,
            engine: store.settings.searchEngine,
            openTabs: tabCandidates,
            archived: closedHere,
            pages: current ? lookup.pages
                : lookup.pages.filter { AddressSuggestions.matches(query, title: $0.title, url: $0.url) },
            pastSearches: current ? lookup.pastSearches
                : lookup.pastSearches.filter { search in words.allSatisfy { search.lowercased().contains($0) } },
            engineSuggestions: current ? lookup.engineSuggestions
                : lookup.engineSuggestions.filter { $0.lowercased().hasPrefix(query.lowercased()) }
        )
        return Shown(openTabs: suggestions.openTabs, pages: suggestions.pages,
                     closed: suggestions.closed, searches: suggestions.searches)
    }

    /// Open tabs with a page, most recently viewed first. Editing this page leaves it out; composing
    /// a new tab lists it first, as the way to edit its address instead.
    private var tabCandidates: [CormorantCore.Tab] {
        let activeID = store.state.activeTabID
        let others = store.tabs.filter { $0.id != activeID }
        let candidates = store.isComposingNewTab ? store.tabs.filter { $0.id == activeID } + others : others
        return candidates.filter { $0.url != nil }
    }

    /// Most recently closed first.
    private var recentlyClosed: [ArchivedTab] {
        closedHere.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Closed tabs that reopen in this Space: like the open tabs, none from another Space, which
    /// choosing would switch to.
    private var closedHere: [ArchivedTab] {
        store.state.archived(reopeningIn: store.state.activeSpaceID)
    }

    /// The typed text, without any completion, once the user has typed; nil for the untouched URL.
    private var query: String? {
        let typed = completion?.typed ?? text
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || typed == initialText ? nil : trimmed
    }

    // MARK: Rows

    private func tabRow(_ tab: CormorantCore.Tab) -> some View {
        let host = tab.url?.displayHost ?? ""
        let isActive = tab.id == store.state.activeTabID
        // Composing a new tab, the tab it was opened from offers its address for editing.
        let editsTab = isActive && store.isComposingNewTab
        return SuggestionRow(
            title: Text(tab.displayTitle), subtitle: host,
            accessibilityLabel: editsTab ? "Edit address: \(tab.displayTitle)" : tab.displayTitle,
            accessibilityValue: editsTab ? host : "\(host), open tab"
        ) {
            FaviconView(favicons: store.favicons, url: tab.url, host: host, side: iconSide, backsDarkIcons: true)
        } trailing: {
            if editsTab {
                Image(systemName: "pencil")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isActive {
                Text("Current")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                SwitchPill()
            }
        } action: {
            if editsTab {
                editActiveTab()
            } else {
                if !isActive { store.activate(tab.id) }
                onDismiss()
            }
        }
        .accessibilityHint(editsTab ? "Edits this tab's address" : isActive ? "Shows this tab" : "Switches to this tab")
    }

    private func pageRow(_ page: HistoryEntry) -> some View {
        let host = page.url.displayHost
        return SuggestionRow(
            title: Text(page.displayTitle), subtitle: page.url.displayString,
            accessibilityLabel: page.displayTitle, accessibilityValue: "\(host), history"
        ) {
            FaviconView(favicons: store.favicons, url: page.url, host: host, side: iconSide, backsDarkIcons: true)
        } trailing: {
            EmptyView()
        } action: {
            store.open(historyPage: page.url)
            onDismiss()
        }
        .accessibilityHint(store.isComposingNewTab || store.activeTab == nil ? "Opens this page in a new tab" : "Opens this page")
    }

    private func closedRow(_ page: ArchivedTab) -> some View {
        let host = page.url.displayHost
        return SuggestionRow(
            title: Text(page.displayTitle), subtitle: host,
            accessibilityLabel: page.displayTitle,
            accessibilityValue: "\(host), closed \(page.archivedAt.formatted(.relative(presentation: .named)))"
        ) {
            FaviconView(favicons: store.favicons, url: page.url, host: host, side: iconSide, backsDarkIcons: true)
        } trailing: {
            Text(Self.age(of: page.archivedAt))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } action: {
            store.restore(page.id)
            onDismiss()
        }
        .accessibilityHint("Reopens this page")
    }

    private func searchRow(_ search: SearchSuggestion) -> some View {
        let kind = switch search.source {
        case .typed: "Search"
        case .history: "Earlier search"
        case .engine: "Suggested search"
        }
        return HStack(spacing: 0) {
            SuggestionRow(
                title: highlighted(search.query), subtitle: nil,
                accessibilityLabel: search.query, accessibilityValue: kind
            ) {
                Image(systemName: search.source == .history ? "clock.arrow.circlepath" : "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: iconSide, height: iconSide)
            } trailing: {
                EmptyView()
            } action: {
                store.search(search.query)
                onDismiss()
            }
            .accessibilityHint("Searches \(store.settings.searchEngine.name)")
            .accessibilityAction(named: "Edit Search") { fill(search.query) }

            if search.source != .typed {
                Button("Edit Search", systemImage: "arrow.up.left") { fill(search.query) }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .accessibilityHidden(true)
            }
        }
    }

    /// `suggestion` with the part past what was typed in bold, as search engines show their suggestions.
    private func highlighted(_ suggestion: String) -> Text {
        guard let typed = query, suggestion.count > typed.count,
              suggestion.lowercased().hasPrefix(typed.lowercased()) else { return Text(suggestion) }
        let split = suggestion.index(suggestion.startIndex, offsetBy: typed.count)
        return Text("\(Text(suggestion[..<split]))\(Text(suggestion[split...]).bold())")
    }

    // MARK: Lookups

    /// History matches at once, then (for a search, not an address) the engine's suggestions after
    /// a pause. Cancelled by the next key.
    private func lookUp() async {
        guard !isTabSearch, let query else {
            lookup = Lookup()
            return
        }
        let history = store.browsingHistory
        let pages = await history?.pages(matching: query) ?? []
        let pastSearches = await history?.searches(matching: query) ?? []
        guard !Task.isCancelled else { return }
        let carried = lookup.engineSuggestions.filter { $0.lowercased().hasPrefix(query.lowercased()) }
        lookup = Lookup(text: query, pages: pages, pastSearches: pastSearches, engineSuggestions: carried)

        let engine = store.settings.searchEngine
        guard store.settings.searchSuggestions, let client = store.searchSuggestions, engine.offersSuggestions,
              SearchSuggestionClient.mayAsk(about: query, engine: engine) else {
            lookup.engineSuggestions = []
            return
        }
        try? await Task.sleep(for: Self.engineDelay)
        guard !Task.isCancelled else { return }
        let suggestions = await client.suggestions(for: query, from: engine)
        guard !Task.isCancelled, lookup.text == query else { return }
        lookup.engineSuggestions = suggestions
    }

    /// Completes the field to a visited site while the user types at its end; never on a deletion,
    /// so backspace takes the completion away and leaves it away.
    private func textDidChange(from old: String, to new: String) {
        // Our own fill, or a suggestion put in to edit: a search stays a search.
        if let completion, new == completion.text { return }
        if let filled, new == filled {
            self.filled = nil
            return
        }
        filled = nil
        let previous = completion
        completion = nil
        // The first key over the selected address replaces all of it, even when it's the address's
        // own first letter ("h" over "https://…").
        let replacesAddress = old == initialText && new.count == 1
        let isDeletion: Bool
        if let previous {
            // Backspace over the selected completion leaves what was typed. Backspace after the
            // completion was accepted (the caret put after it) leaves all of it but its last letter;
            // that's told from typing its next letter by length, except for a two-letter suffix.
            isDeletion = previous.typed.hasPrefix(new)
                || (previous.text.hasPrefix(new) && new.count == previous.text.count - 1
                    && new.count != previous.typed.count + 1)
        } else {
            isDeletion = old.hasPrefix(new) && new.count < old.count && !replacesAddress
        }
        // Typing over a completion or the address replaces a selection, so the caret is at the end by
        // definition (and the selection binding may still hold the old range).
        guard !isDeletion, !isTabSearch, new != initialText, new.allSatisfy(\.isASCII),
              previous != nil || replacesAddress || caretIsAtEnd(of: new),
              let found = InlineCompletion(completing: new, from: completionHosts) else { return }
        apply(found)
    }

    private func apply(_ found: InlineCompletion) {
        completion = found
        text = found.text
        // In the same update as the text: set any later, the caret stays where the key went in, and
        // the next key lands in front of the suffix. Again once the text has reached the field, in
        // case that moved the caret.
        selectSuffix(of: found)
        Task { selectSuffix(of: found) }
    }

    private func selectSuffix(of found: InlineCompletion) {
        guard text == found.text, completion == found else { return }
        let start = text.index(text.startIndex, offsetBy: found.typed.count)
        selection = TextSelection(range: start..<text.endIndex)
    }

    /// No selection (or none known), or a caret at the end of `text`.
    private func caretIsAtEnd(of text: String) -> Bool {
        guard !text.isEmpty, case .selection(let range)? = selection?.indices else { return true }
        // The binding can lag the text by a keystroke; a caret past the old end is still the end.
        return range.isEmpty && range.lowerBound >= text.index(before: text.endIndex)
    }

    // MARK: Actions

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isTabSearch {
            // The best match; with none, the text is searched for in a new tab instead.
            if let tab = shown.openTabs.first {
                if tab.id != store.state.activeTabID { store.activate(tab.id) }
            } else {
                store.submit(text, inNewTab: true)
            }
        } else {
            store.submit(text)
        }
        onDismiss()
    }

    /// Puts a suggestion in the field to edit, the caret at its end.
    private func fill(_ query: String) {
        completion = nil
        filled = query
        text = query
        isFocused.wrappedValue = true
        fieldHasVoiceOver = true
        Task { selection = TextSelection(insertionPoint: text.endIndex) }
    }

    /// Switches from composing a new tab to editing the active one, with its URL selected in the field.
    private func editActiveTab() {
        store.cancelComposing()
        completion = nil
        text = store.activeTab?.url?.absoluteString ?? ""
        initialText = text
        isFocused.wrappedValue = true
        fieldHasVoiceOver = true
        // After the new text has reached the field, or setting it moves the caret to the end.
        Task { selectAll() }
    }

    private func selectAll() {
        selection = text.isEmpty ? nil : TextSelection(range: text.startIndex..<text.endIndex)
    }

    private static func tabCount(_ count: Int) -> String {
        count == 1 ? "1 Open Tab" : "\(count) Open Tabs"
    }

    /// "5m", "3h", "2d": enough to tell this morning from last week in a narrow column.
    private static func age(of date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(max(minutes, 1))m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// A light heading over the rows: Search Tabs' count of tabs and matches.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Marks an open tab's row: tapping goes to that tab rather than loading the page again.
private struct SwitchPill: View {
    var body: some View {
        Label("Switch", systemImage: "square.on.square")
            .labelStyle(.titleAndIcon)
            .font(.footnote.weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(Color(.brandCyanForeground))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color(.brandCyan), in: .capsule)
            .fixedSize()
    }
}

/// One result: an icon, a title over an optional subtitle, and a trailing hint of what tapping does.
private struct SuggestionRow<Leading: View, Trailing: View>: View {
    let title: Text
    let subtitle: String?
    let accessibilityLabel: String
    let accessibilityValue: String
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.body)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}

