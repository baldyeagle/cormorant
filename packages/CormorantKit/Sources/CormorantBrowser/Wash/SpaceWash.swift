import CormorantCore
import SwiftUI

/// `SpaceWashPainter`'s wash, live, in `color`: from its first frame each time it appears (at launch,
/// the launch screen's picture). A new color is eased into from wherever the last one had got to: the
/// launch color into the Space's at launch, one Space's into the next's. With Reduce Motion it holds
/// its first frame (colors still ease). Holding still (`holdsStill`), it stays on its first frame in
/// `color`, a new color drawn at once: UI tests ask for that, as CI's runners draw without a GPU, and thirty blurred frames a
/// second took the cores a loading page needed.
public struct SpaceWash: View {
    let color: SpaceWashPainter.RGB
    let holdsStill: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = Clock()
    /// The color being eased from, and when (on `clock`) that began; nil once there's nothing to ease.
    @State private var shift: Shift?

    private struct Shift: Equatable {
        let from: SpaceWashPainter.RGB
        let began: Double
    }

    private static let shiftDuration = 1.2
    /// A beat takes 5.5 s: 30 frames a second is plenty, and half the work of 60.
    private static let frameInterval = 1.0 / 30
    /// Drawn at this fraction of its size and scaled up: it's all blur, so a sixteenth of the pixels
    /// looks the same.
    private static let resolution = 0.25

    public init(color: SpaceWashPainter.RGB, holdsStill: Bool = false) {
        self.color = color
        self.holdsStill = holdsStill
    }

    public var body: some View {
        Group {
            if holdsStill {
                canvas { (0, color) }
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: reduceMotion && shift == nil)) { timeline in
                    canvas {
                        let time = clock.time(at: timeline.date)
                        return (reduceMotion ? 0 : time, shownColor(at: time))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: color) { old, _ in
            guard !holdsStill else { return }
            shift = Shift(from: shownColor(at: clock.time, easingTo: old), began: clock.time)
        }
        .task(id: shift) {
            // Over once the clock has run the length of it (it stands still while frames do).
            while let shift, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.shiftDuration))
                if clock.time - shift.began >= Self.shiftDuration { self.shift = nil }
            }
        }
    }

    /// The wash at a quarter of its size, scaled up, at the time and in the color `frame` gives when drawn.
    private func canvas(_ frame: @escaping () -> (time: Double, color: SpaceWashPainter.RGB)) -> some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let frame = frame()
                SpaceWashPainter.draw(in: context, size: size, time: frame.time, color: frame.color, dark: colorScheme == .dark)
            }
            .frame(width: proxy.size.width * Self.resolution, height: proxy.size.height * Self.resolution)
            .scaleEffect(1 / Self.resolution, anchor: .topLeading)
        }
    }

    /// The color on screen at `time` on `clock`, part way from `shift`'s to `target` (by default `color`).
    private func shownColor(at time: Double, easingTo target: SpaceWashPainter.RGB? = nil) -> SpaceWashPainter.RGB {
        let target = target ?? color
        guard let shift else { return target }
        let progress = min(1, max(0, (time - shift.began) / Self.shiftDuration))
        // Eased in as well as out: at launch it starts on the frame after a stall, where a quick start shows.
        return shift.from.mixed(with: target, by: progress * progress * (3 - 2 * progress))
    }

    /// The wash's own time: it runs with the frames drawn, at most a few frames' worth between two, so a
    /// stall (the app still starting up just after its first frame) holds the picture where it was
    /// rather than jumping it ahead. Starts at zero with the first frame.
    private final class Clock {
        private static let longestStep = 0.1
        private(set) var time = 0.0
        private var last: Date?

        func time(at date: Date) -> Double {
            if let last { time += min(max(0, date.timeIntervalSince(last)), Self.longestStep) }
            last = date
            return time
        }
    }
}

extension SpaceWashPainter.RGB {
    public init(_ color: CormorantCore.RGBColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

extension BrowserStore {
    /// The wash is up: behind the bird at launch and on a blank tab, and over a new tab's page until
    /// it has drawn (`TabSession.isAwaitingFirstPaint`), but not over a load error.
    public var showsWash: Bool {
        guard isLoaded, activeTab?.url != nil, let session = activeSession else { return true }
        return session.isAwaitingFirstPaint && session.loadError == nil
    }
}
