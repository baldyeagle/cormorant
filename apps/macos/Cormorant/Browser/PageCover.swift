import AppKit
import CormorantBrowser
import CormorantCore
import SwiftUI

/// Over the page, in its frame: the Space's wash until a new tab's first page has drawn
/// (`BrowserStore.showsWash`), so WebKit's white canvas never flashes, and the bird on the wash when
/// there's nothing to show (no tab, a blank one, tabs still loading). At launch the bird stays until
/// the page the window opens on has drawn, as the iPhone's launch screen does, and the wash starts in
/// the launch screen's cyan and eases into the Space's.
struct PageCover: View {
    let store: BrowserStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLaunching = true

    var body: some View {
        ZStack {
            if store.showsWash {
                SpaceWash(color: washColor)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
            if showsBird {
                Image(.cormorantMark)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 128, maxHeight: 128)
                    .padding(8)
                    .accessibilityHidden(true)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The page's own frame, not the window's: no title bar inset.
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.35), value: store.showsWash)
        .animation(.easeOut(duration: 0.35), value: showsBird)
        .onChange(of: store.showsWash) { _, shows in if !shows { isLaunching = false } }
        // Launched with nothing to open (or onto a blank tab): no launch to see through, so a page
        // opened from here gets the wash alone, without the bird.
        .onChange(of: store.isLoaded && store.activeTab?.url == nil, initial: true) { _, blank in
            if blank { isLaunching = false }
        }
    }

    private var showsBird: Bool {
        !store.isLoaded || store.activeTab?.url == nil || (isLaunching && store.showsWash)
    }

    /// The launch screen's color until the tabs, and so the Space, are loaded; then the Space's.
    private var washColor: SpaceWashPainter.RGB {
        guard store.isLoaded else { return SpaceWashPainter.launchColor(dark: colorScheme == .dark) }
        return SpaceWashPainter.RGB(store.state.activeSpace.color.rgb)
    }
}

/// Hosts `PageCover` over the web view. Never in the way: clicks, scrolls and the swipe go through to
/// the page, which is under it.
final class PageCoverView: NSHostingView<PageCover> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
