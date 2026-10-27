import SwiftUI
import UIKit

/// A page's card growing into the page: from where the card is drawn to where the browser draws the
/// page, over a backdrop that fades in to hide what's around it. One animation for both ways a card
/// opens a tab: a tapped card in the tab switcher, and a tapped link preview (`CardExpansionOverlay`).
/// The tab is already showing its page underneath; when this finishes, the caller swaps to it without
/// animating. With Reduce Motion (or a card never laid out) there's no growing, just a quick fade to
/// the page.
///
/// Rects are in this view's coordinate space, which callers make the window's (full screen, no safe
/// area).
struct CardExpansion: View {
    /// The card as it's drawn when tapped.
    struct Card {
        let frame: CGRect
        /// Its tilt in the switcher's fan.
        var tilt: Double = 0
        var topRadius: CGFloat = 0
        var bottomRadius: CGFloat = 0
    }

    let card: Card
    /// The page as the card shows it, pinned to the top.
    let snapshot: PageSnapshot?
    /// Shown instead when there's no snapshot.
    let host: String
    /// Where the browser draws the page, as the card shows it: below the status bar (the page may run
    /// under it, but cards start at the page's content) and down to the bottom edge under the bar
    /// (see BrowserView's WebViewContainer).
    let page: CGRect
    /// Fades in behind the card: the color behind the browser's status bar for the tab (its page's
    /// background), so the page lands with no seam (`BrowserStore.stripColor(in:)`). Read as it draws,
    /// so it follows the page's color should it settle while the card grows.
    let backdrop: () -> Color
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    /// The backdrop for a UIKit caller: the strip's color, or the default strip's without one.
    static func backdrop(stripColor: UIColor?) -> Color {
        Color(uiColor: stripColor ?? UIColor(resource: .launchBackground))
    }

    var body: some View {
        let fades = reduceMotion || card.frame.isEmpty
        let frame = expanded || fades ? page : card.frame
        let top: CGFloat = expanded ? 0 : card.topRadius
        let bottom: CGFloat = expanded ? 0 : card.bottomRadius
        ZStack(alignment: .topLeading) {
            backdrop().opacity(expanded ? 1 : 0)
            // What the page shows behind the status bar, fading in with the backdrop above the card.
            if let band = snapshot?.statusBand, page.minY > 0 {
                Image(uiImage: band)
                    .resizable()
                    .frame(width: page.width, height: page.minY)
                    .position(x: page.midX, y: page.minY / 2)
                    .opacity(expanded ? 1 : 0)
            }
            TabPreview(snapshot: snapshot?.content, host: host, width: frame.width)
                .frame(width: frame.width, height: frame.height)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                                  bottomTrailingRadius: bottom, topTrailingRadius: top,
                                                  style: .continuous))
                .rotationEffect(.degrees(expanded ? 0 : card.tilt))
                .opacity(fades && !expanded ? 0 : 1)
                .position(x: frame.midX, y: frame.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .accessibilityHidden(true)
        .onAppear {
            // No bounce: the snapshot has to come to rest exactly on the page it hands over to.
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.22)) {
                expanded = true
            } completion: {
                onFinished()
            }
        }
    }
}

/// Plays `CardExpansion` over everything in a window, for a card that isn't in the app's own view
/// tree: the link menu's preview, whose menu is drawn above the app. Removes itself when it's done.
@MainActor
enum CardExpansionOverlay {
    static func play(in window: UIWindow, card: CardExpansion.Card, snapshot: PageSnapshot?, host: String,
                     page: CGRect, backdrop: @escaping () -> Color) {
        let ending = Ending()
        let controller = UIHostingController(rootView: CardExpansion(
            card: card, snapshot: snapshot, host: host, page: page, backdrop: backdrop,
            // Not torn down from inside its own animation's completion.
            onFinished: { Task { @MainActor in ending.end() } }
        ).ignoresSafeArea())
        // Window coordinates, as the rects are.
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.frame = window.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(controller.view)
        ending.view = controller.view
        // Kept until it ends; the ending lets it go.
        ending.controller = controller
        // Should a completion not arrive, nothing is left over the window.
        Task {
            try? await Task.sleep(for: .seconds(2))
            ending.end()
        }
    }

    private final class Ending {
        weak var view: UIView?
        var controller: AnyObject?
        func end() {
            // The page is underneath already: no fade, as when the switcher's card hands over.
            view?.removeFromSuperview()
            controller = nil
        }
    }
}
