import SwiftUI

/// Tabs on the left, the search/URL pill in the middle, page actions on the right.
/// Shrinks to a hostname capsule while scrolling down; tapping it expands the bar again.
/// The presenter caps Dynamic Type at `.accessibility1` (the scaled control sizes read it too).
struct BottomBar: View {
    @Environment(BrowserStore.self) private var store
    let session: TabSession?
    let url: URL?
    /// True while the search panel is open; the bar stays expanded (and hidden) under it.
    let isSearching: Bool
    let showSwitcher: () -> Void
    let showSearch: () -> Void
    let showActions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Scales the round controls with Dynamic Type; a minimum, never a cap.
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = 46

    private var isCollapsed: Bool { (session?.isBarCollapsed ?? false) && !isSearching }
    private var isLoading: Bool { session?.isLoading == true }
    private var progress: Double { session?.progress ?? 0 }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedStrip
                    .transition(stripTransition)
            } else {
                fullBar
                    .transition(stripTransition)
            }
        }
        .animation(.snappy(duration: 0.22), value: isCollapsed)
        // Collapsed, the capsule sinks toward the home indicator like Safari's, so the whole
        // thing is a sliver rather than a label stacked above the safe area. Not with Reduce Motion:
        // the change of state is then a pure fade.
        .padding(.bottom, isCollapsed && !reduceMotion ? -14 : 0)
    }

    private var stripTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom))
    }

    // MARK: Collapsed

    private var collapsedStrip: some View {
        Button {
            session?.isBarCollapsed = false
        } label: {
            Text(url?.displayHost ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                // Wide enough for the progress line to read under a short host like "x.com".
                .frame(minWidth: 140)
                .overlay(alignment: .bottom) { LoadingLine(progress: progress, isLoading: isLoading) }
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityLabel(url.map { "Show toolbar, \($0.displayHost)" } ?? "Show toolbar")
    }

    // MARK: Expanded

    private var fullBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                tabsButton
                searchPill
                actionsButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Tap opens the switcher; long-press offers New Tab.
    private var tabsButton: some View {
        Menu {
            Button("New Tab", systemImage: "plus") { store.newTab() }
                .labelStyle(.titleAndIcon)
        } label: {
            TabCountGlyph(count: store.tabs.count)
                .frame(minWidth: controlSize, minHeight: controlSize)
                .contentShape(.circle)
        } primaryAction: {
            showSwitcher()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Tabs, \(store.tabs.count) open")
        .accessibilityHint("Shows open tabs")
        .accessibilityAction(named: "New Tab") { store.newTab() }
    }

    private var searchPill: some View {
        Button(action: showSearch) {
            Group {
                if let url {
                    Text(url.displayHost)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                } else {
                    Label("Search or enter address", systemImage: "magnifyingglass")
                        .labelStyle(.titleAndIcon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: controlSize)
            .overlay(alignment: .bottom) { LoadingLine(progress: progress, isLoading: isLoading) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Address")
        .accessibilityValue(url?.displayHost ?? "")
        .accessibilityHint("Search or enter address")
    }

    private var actionsButton: some View {
        Button(action: showActions) {
            Image(systemName: "chevron.up")
                .font(.body.weight(.semibold))
                .frame(minWidth: controlSize, minHeight: controlSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Page actions")
    }
}

/// The open-tab count in a rounded square, the same glyph the switcher uses as its metaphor.
private struct TabCountGlyph: View {
    let count: Int
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 24
    @ScaledMetric(relativeTo: .footnote) private var radius: CGFloat = 6

    var body: some View {
        Text(count < 100 ? "\(count)" : "∞")
            .font(.footnote.weight(.bold))
            .monospacedDigit()
            // A background tab opened from the link menu ticks the count over.
            .contentTransition(.numericText(value: Double(count)))
            .animation(.snappy, value: count)
            .padding(.horizontal, 4)
            .frame(minWidth: side, minHeight: side)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(lineWidth: 1.6))
            .foregroundStyle(.primary)
    }
}

/// A hairline of page-load progress along the bottom edge of the control it overlays.
private struct LoadingLine: View {
    let progress: Double
    let isLoading: Bool

    var body: some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
            .scaleEffect(x: 1, y: 0.6, anchor: .bottom)
            .padding(.horizontal, 16)
            .padding(.bottom, 2)
            .opacity(isLoading ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: isLoading)
            .accessibilityHidden(true)
    }
}
