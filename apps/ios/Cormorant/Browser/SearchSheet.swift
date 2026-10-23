import CormorantCore
import SwiftUI

/// The search panel: an in-place overlay (not a `.sheet`) that rides on the keyboard, with the
/// full URL selected in the field and, below it, other open tabs and recently archived pages.
/// Closes on submit, on choosing a row, on a tap outside, on a swipe down, on Escape, and when
/// the keyboard goes away; the owner does that by watching `isFocused`.
struct SearchSheet: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL?
    var isFocused: FocusState<Bool>.Binding
    let onDismiss: () -> Void
    /// False over the empty state: there's no page to dim, so the launch screen's background stays put.
    var dimsPage = true
    /// The panel's top edge in global coordinates, so the empty state can keep its mark above it.
    var onPanelTopChange: (CGFloat) -> Void = { _ in }

    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var initialText = ""
    @State private var dragOffset: CGFloat = 0
    /// The URL is selected once, when focus first lands; refocusing later keeps the user's caret.
    @State private var didSelectInitially = false
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 48

    private static let rowLimit = 6
    private static let dismissDistance: CGFloat = 70

    var body: some View {
        ZStack(alignment: .bottom) {
            scrim
            panel
                .offset(y: dragOffset)
                // Outside the drag offset: where the panel rests, not where a finger holds it.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onPanelTopChange($0) }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
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
    }

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

    private var panel: some View {
        VStack(spacing: 0) {
            grabber
            field
                .padding(.horizontal, 12)
                .layoutPriority(1)
            results
        }
        .padding(.bottom, 8)
        .frame(maxWidth: 640)
        // Tinted toward the background so titles stay legible over busy pages.
        .glassEffect(.regular.tint(Color(.systemBackground).opacity(0.4)),
                     in: .rect(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityAction(.escape) { onDismiss() }
    }

    /// The handle doubles as the swipe-down target, so dragging never fights text selection.
    /// Measured in global space: the handle rides the offset it drives, so local translations
    /// would feed back and make the panel stutter between two positions.
    private var grabber: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { dragOffset = max(0, $0.translation.height) }
                    .onEnded { value in
                        if value.translation.height > Self.dismissDistance
                            || value.predictedEndTranslation.height > Self.dismissDistance * 2 {
                            onDismiss()
                        } else {
                            withAnimation(.snappy) { dragOffset = 0 }
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search or enter address", text: $text, selection: $selection)
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
                .accessibilityLabel("Search or enter address")
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

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        let tabs = openTabs
        let pages = recentPages
        if !tabs.isEmpty || !pages.isEmpty {
            // Hugs its rows when they fit; scrolls (and gives up height to the field) when they don't,
            // e.g. landscape with the keyboard up.
            ViewThatFits(in: .vertical) {
                rows(tabs: tabs, pages: pages)
                ScrollView {
                    rows(tabs: tabs, pages: pages)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.top, 6)
        }
    }

    private func rows(tabs: [CormorantCore.Tab], pages: [ArchivedTab]) -> some View {
        VStack(spacing: 0) {
            ForEach(tabs) { tab in
                SearchRow(title: tab.displayTitle, host: tab.url?.displayHost ?? "") {
                    Image(systemName: "square.on.square")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } action: {
                    store.activate(tab.id)
                    onDismiss()
                }
                .accessibilityHint("Switches to this tab")
            }
            ForEach(pages) { page in
                SearchRow(title: page.displayTitle, host: page.url.displayHost) {
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
        }
        .padding(.horizontal, 12)
    }

    /// The query narrows the lists once the user has typed; the untouched URL shows everything.
    private var query: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || text == initialText ? nil : trimmed
    }

    private func matches(_ title: String, _ url: URL?) -> Bool {
        guard let query else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || (url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// Open tabs with a page, most recently viewed first. Editing this page leaves it out; composing
    /// a new tab keeps it, since going back to it is a real choice then.
    private var openTabs: [CormorantCore.Tab] {
        let excluded = store.isComposingNewTab ? nil : store.state.activeTabID
        return Array(store.tabs
            .filter { $0.id != excluded && $0.url != nil && matches($0.displayTitle, $0.url) }
            .prefix(Self.rowLimit))
    }

    /// Most recently archived pages.
    private var recentPages: [ArchivedTab] {
        Array(store.state.archived
            .sorted { $0.archivedAt > $1.archivedAt }
            .filter { matches($0.displayTitle, $0.url) }
            .prefix(Self.rowLimit))
    }

    // MARK: Actions

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.submit(text)
        onDismiss()
    }

    private func selectAll() {
        selection = text.isEmpty ? nil : TextSelection(range: text.startIndex..<text.endIndex)
    }

    /// "5m", "3h", "2d": enough to tell this morning from last week in a narrow column.
    private static func age(of date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(max(minutes, 1))m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// One result: a host monogram, the page title, and a trailing hint of what tapping does.
private struct SearchRow<Trailing: View>: View {
    let title: String
    let host: String
    @ViewBuilder let trailing: Trailing
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(host.first.map { String($0).uppercased() } ?? "?")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: badge, height: badge)
                    .background(HostTint.color(for: host), in: .rect(cornerRadius: badge * 0.26, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(host)
    }
}
