import CormorantBlocking
import SwiftUI
import UIKit
import WebKit

/// The caret sheet: back/forward, the host (tap to search), copy and reload, Find on Page and
/// Share, page zoom, desktop site, per-site blockers, and Settings.
///
/// The presenter must call `session.runPendingAction()` from the sheet's `onDismiss`: Find on
/// Page needs first responder, which it can only take once the sheet is gone. `showSearch` is the
/// presenter's and dismisses the sheet itself.
///
/// Settings stacks on top rather than replacing the sheet: `onDismiss` fires a second or more after
/// a sheet has visibly gone, which left a blank gap before Settings appeared.
struct ActionsSheet: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: TabSession?
    let url: URL?
    let showSearch: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let session, let url = pageURL {
                    NavigationRow(session: session, url: url, dismiss: dismiss, showSearch: showSearch)
                    tiles(session: session, url: url)
                    pageGroup(session: session)
                }
                siteGroup
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Sized to the content so nothing is cut off at the resting detent; .large stays available
        // for accessibility sizes where the content outgrows the screen.
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        // Opaque enough that text contrast doesn't depend on the page behind (dark mode over a light page).
        .presentationBackground(.regularMaterial)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// The tab's page, if it is a web page. New tabs (nil) and `about:blank` popups get only Settings.
    private var pageURL: URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    // MARK: Tiles

    private func tiles(session: TabSession, url: URL) -> some View {
        TileRow {
            Button {
                session.pendingAction = .findOnPage
                dismiss()
            } label: {
                TileLabel(title: "Find on Page", systemImage: "doc.text.magnifyingglass")
            }
            ShareLink(item: url) {
                TileLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(TileButtonStyle())
    }

    // MARK: Page

    private func pageGroup(session: TabSession) -> some View {
        RowGroup {
            PageZoomRow(session: session)
            RowDivider()
            Button {
                session.toggleDesktopSite()
                dismiss()
            } label: {
                ActionRow(
                    title: session.isDesktopSite ? "Request Mobile Site" : "Request Desktop Site",
                    systemImage: session.isDesktopSite ? "iphone" : "laptopcomputer"
                )
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    // MARK: Site and app

    /// The host blockers are keyed on: the web view's, else the tab's, as `toggleBlockingForActiveSite()` uses.
    private func blockingHost(session: TabSession?) -> String? {
        guard let host = (session?.webView.url ?? url)?.host(), !host.isEmpty else { return nil }
        return host
    }

    private var siteGroup: some View {
        RowGroup {
            if pageURL != nil, let host = blockingHost(session: session) {
                let site = Self.displayHost(host)
                if store.blocking.preferences.isEnabled {
                    let isBlocking = store.blocking.isBlocking(host: host)
                    Toggle(isOn: Binding(
                        get: { store.blocking.isBlocking(host: host) },
                        set: { new in
                            // A repeated write must not flip it back (and reload again).
                            guard new != store.blocking.isBlocking(host: host) else { return }
                            store.toggleBlockingForActiveSite()
                            dismiss()
                        }
                    )) {
                        ActionRow(
                            title: "Block ads & trackers",
                            subtitle: isBlocking
                                ? Text("Page looks broken? Turn blockers off for \(Text(site).bold())")
                                : Text("Off for \(Text(site).bold()). Other sites are still blocked."),
                            systemImage: "shield.lefthalf.filled"
                        )
                        .padding(.trailing, -16)
                    }
                    .padding(.trailing, 16)
                } else {
                    ActionRow(title: "Blockers are off", subtitle: Text("Turn them on in Settings."), systemImage: "shield.slash")
                        .accessibilityElement(children: .combine)
                }
                RowDivider()
            }
            Button {
                showSettings = true
            } label: {
                ActionRow(title: "Settings", systemImage: "gearshape")
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private static func displayHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Top row

/// Back, Forward, the host, Copy Link, and Reload/Stop in one capsule. Tapping the host opens the
/// search panel, like the bar's pill. At accessibility text sizes the host moves above the buttons
/// so neither gets crushed.
private struct NavigationRow: View {
    @Environment(BrowserStore.self) private var store
    let session: TabSession
    let url: URL
    let dismiss: DismissAction
    let showSearch: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Matches IconButtonStyle's size, so the host's pressed highlight fills the row's height.
    @ScaledMetric(relativeTo: .body) private var hostHeight: CGFloat = 44
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 4) {
                    host.padding(.top, 12).padding(.horizontal, 20)
                    HStack(spacing: 0) {
                        back; forward
                        Spacer(minLength: 0)
                        copy; reloadOrStop
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                .background(.fill.tertiary, in: .rect(cornerRadius: 28))
            } else {
                HStack(spacing: 0) {
                    back; forward
                    host.frame(maxWidth: .infinity)
                    copy; reloadOrStop
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: .capsule)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(IconButtonStyle())
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    /// The whole space between the button pairs is the tap target, not just the text.
    private var host: some View {
        Button(action: showSearch) {
            Text(url.displayHost)
                .font(.headline)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: min(hostHeight, 76))
                .contentShape(.capsule)
        }
        // Overrides the row's IconButtonStyle, which would squeeze the host into a 44pt circle.
        .buttonStyle(HostButtonStyle())
        .accessibilityLabel("Address")
        .accessibilityValue(url.displayHost)
        .accessibilityHint("Search or enter address")
    }

    /// On the first page of a tab a link opened, closes it, like the edge swipe.
    private var back: some View {
        let closesTab = !session.canGoBack && !session.isRestoringHistory && store.closesOnBackSwipe(session.tabID)
        return Button("Back", systemImage: "chevron.backward") {
            if closesTab { store.close(session.tabID) } else { session.goBack() }
            dismiss()
        }
        .disabled(!session.canGoBack && !closesTab)
        .accessibilityHint(closesTab ? "Closes this tab" : "")
    }

    private var forward: some View {
        Button("Forward", systemImage: "chevron.forward") {
            session.goForward()
            dismiss()
        }
        .disabled(!session.canGoForward)
    }

    private var copy: some View {
        Button(copied ? "Link Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") {
            UIPasteboard.general.url = url
            #if DEBUG
            OwnPasteboardWrite.record()
            #endif
            AccessibilityNotification.Announcement("Link copied").post()
            copied = true
            resetCopied?.cancel()
            resetCopied = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        }
        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
    }

    /// Reads `session.isLoading`, so it flips live while the sheet is open.
    @ViewBuilder private var reloadOrStop: some View {
        if session.isLoading {
            Button("Stop Loading", systemImage: "xmark") { session.reloadOrStop() }
        } else {
            Button("Reload", systemImage: "arrow.clockwise") {
                session.reloadOrStop()
                dismiss()
            }
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// Capped so four of them still fit one iPhone row at the largest text sizes.
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .frame(width: min(size, 76), height: min(size, 76))
            .contentShape(.circle)
            .background(.primary.opacity(configuration.isPressed ? 0.1 : 0), in: .circle)
    }
}

private struct HostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(.primary.opacity(configuration.isPressed ? 0.1 : 0), in: .capsule)
    }
}

// MARK: - Tiles

private struct TileRow<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout { content }
    }
}

private struct TileLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(.vertical, 8)
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(.fill.tertiary, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22).fill(.primary.opacity(configuration.isPressed ? 0.08 : 0))
            }
            .contentShape(.rect(cornerRadius: 22))
    }
}

// MARK: - Rows

private struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.fill.tertiary, in: .rect(cornerRadius: 24))
            .clipShape(.rect(cornerRadius: 24))
    }
}

private enum RowMetrics {
    static let horizontalPadding: CGFloat = 16
    static let iconSpacing: CGFloat = 14
}

/// Icon column, title, and an optional trailing accessory.
private struct ActionRow<Trailing: View>: View {
    let title: String
    var subtitle: Text? = nil
    let systemImage: String
    @ViewBuilder var trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 54

    var body: some View {
        HStack(spacing: RowMetrics.iconSpacing) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    subtitle
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight)
        .contentShape(.rect)
    }
}

extension ActionRow where Trailing == EmptyView {
    init(title: String, subtitle: Text? = nil, systemImage: String) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

/// Inset to line up with row titles, past the icon column.
private struct RowDivider: View {
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        Divider().padding(.leading, RowMetrics.horizontalPadding + iconWidth + RowMetrics.iconSpacing)
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

/// Page Zoom with Safari's − percent + control; tapping the percent resets to 100%.
/// VoiceOver gets one adjustable element ("Page Zoom, 115 percent") plus a reset action.
/// At accessibility text sizes the control moves under the title.
private struct PageZoomRow: View {
    let session: TabSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var stepWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var stepHeight: CGFloat = 36

    private var percent: Int { Int((session.pageZoom * 100).rounded()) }
    private var isDefault: Bool { percent == 100 }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    ActionRow(title: "Page Zoom", systemImage: "textformat.size")
                    stepper
                        .padding(.horizontal, RowMetrics.horizontalPadding)
                        .padding(.bottom, 12)
                }
            } else {
                ActionRow(title: "Page Zoom", systemImage: "textformat.size") { stepper }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page Zoom")
        .accessibilityValue("\(percent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(session.zoomIn)
            case .decrement: change(session.zoomOut)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset to 100 percent") { change(session.resetZoom) }
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            Button { change(session.zoomOut) } label: {
                Label("Zoom Out", systemImage: "minus")
                    .frame(width: stepWidth, height: stepHeight)
            }
            .disabled(!session.canZoomOut)
            Button { change(session.resetZoom) } label: {
                Text("\(percent)%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent)))
                    .foregroundStyle(isDefault ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(minWidth: stepWidth * 1.3, minHeight: stepHeight)
            }
            .disabled(isDefault)
            Button { change(session.zoomIn) } label: {
                Label("Zoom In", systemImage: "plus")
                    .frame(width: stepWidth, height: stepHeight)
            }
            .disabled(!session.canZoomIn)
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.medium))
        .buttonStyle(StepButtonStyle())
        .background(.fill.tertiary, in: .capsule)
    }

    /// Animates the percent's digits, unless Reduce Motion is on.
    private func change(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), action)
    }
}

private struct StepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(.rect)
    }
}
