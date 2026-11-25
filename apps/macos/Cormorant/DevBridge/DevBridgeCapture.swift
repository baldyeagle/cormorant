#if DEBUG
import AppKit
import UniformTypeIdentifiers
import WebKit

/// Pictures of the page and the window, drawn in-process (no Screen Recording). WebKit draws the page
/// in another process, so a capture of the window leaves it blank: the page's own snapshot is pasted
/// in where it is.
enum DevBridgeCapture {
    static func page(_ webView: WKWebView) async throws -> CGImage {
        let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DevBridgeFailure("The page's snapshot had no bitmap")
        }
        return cgImage
    }

    /// The window as drawn, each web view's snapshot in its place, `scale` pixels to a point. `webViews`
    /// gives the web views on show; it's asked again after their pictures are taken, and one no longer
    /// on show (the tab changed meanwhile) isn't pasted.
    static func window(_ window: NSWindow, webViews: () -> [WKWebView], scale: CGFloat) async throws -> CGImage {
        var pictures: [(webView: WKWebView, image: CGImage)] = []
        for webView in webViews() where webView.window === window {
            if let image = try? await page(webView) { pictures.append((webView, image)) }
        }
        guard let content = window.contentView, let root = (content.superview ?? content).layer else {
            throw DevBridgeFailure("The window has no layer to draw")
        }
        // The pasted page goes in the page's own view, so whatever is over the page (the peeking sidebar,
        // the bar, a toast) is drawn over it as on screen. It's added and taken out before the screen
        // next draws.
        let shown = webViews()
        var pasted: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (webView, image) in pictures where shown.contains(where: { $0 === webView }) && webView.window === window {
            guard let host = webView.superview?.layer else { continue }
            let layer = CALayer()
            layer.frame = webView.frame
            layer.contents = image
            layer.contentsGravity = .resize
            host.addSublayer(layer)
            pasted.append(layer)
        }
        CATransaction.commit()
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pasted.forEach { $0.removeFromSuperlayer() }
            CATransaction.commit()
        }
        let size = root.bounds.size
        guard let context = CGContext(data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw DevBridgeFailure("Couldn't make a bitmap") }
        context.scaleBy(x: scale, y: scale)
        // Under the window's own corners, its background.
        context.setFillColor(window.backgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        root.render(in: context)
        guard let image = context.makeImage() else { throw DevBridgeFailure("Couldn't draw the window") }
        return image
    }

    /// Any of the app's windows, with a note when it isn't as on screen. A window whose layers draw
    /// nothing (a menu) is drawn again through its views' own drawing.
    static func anyWindow(_ window: NSWindow, scale: CGFloat) async throws -> (image: CGImage, note: String?) {
        let image = try await self.window(window, webViews: { DevBridgeWindows.webViews(in: window) }, scale: scale)
        guard isBlank(image) else { return (image, nil) }
        if let root = window.contentView?.superview ?? window.contentView,
           let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            if let drawn = rep.cgImage, drawn.width > 0, !isBlank(drawn) {
                return (scaled(drawn, by: scale * root.bounds.width / CGFloat(drawn.width)),
                        "Its layers drew nothing, so this is its views' own drawing: materials and effects are left out.")
            }
        }
        return (image, "It came out blank: what it shows is drawn by another process or by the system.")
    }

    /// All one color (the centre's) away from the edges, where a panel's rounded corners are.
    private static func isBlank(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32, image.width > 0, image.height > 0,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let base = UnsafeRawPointer(bytes)
        func pixel(_ column: Int, _ row: Int) -> UInt32 {
            base.loadUnaligned(fromByteOffset: row * image.bytesPerRow + column * 4, as: UInt32.self)
        }
        let centre = pixel(image.width / 2, image.height / 2)
        let insetX = image.width / 8, insetY = image.height / 8
        var others = 0
        let allowed = image.width * image.height / 500
        for row in insetY..<(image.height - insetY) {
            for column in insetX..<(image.width - insetX) where pixel(column, row) != centre {
                others += 1
                if others > allowed { return false }
            }
        }
        return true
    }

    /// `image` at `scale` of its size, for a smaller picture.
    static func scaled(_ image: CGImage, by scale: CGFloat) -> CGImage {
        guard scale != 1 else { return image }
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func encode(_ image: CGImage, as type: UTType, quality: CGFloat = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Trackpad scrolls, made as the trackpad makes them (pixel deltas with began/changed/ended phases)
/// and put on the app's own event queue, so they go through the window's event monitors and on to
/// the view under them as real ones do. Never posted to the system: that would need Accessibility.
enum DevBridgeGesture {
    /// A gesture left with its fingers down, for the next to carry on or end.
    private(set) static var held: (window: NSWindow, point: CGPoint)?

    /// A scroll event in `window` at `point` (from its top-left corner). Made from a pointer event, which
    /// can be given its window and place, then turned into a scroll: a scroll made from scratch can't be.
    private static func scrollEvent(_ phase: NSEvent.Phase, delta: (x: Int64, y: Int64), at point: CGPoint,
                                    in window: NSWindow) -> NSEvent? {
        guard let pointer = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: point.x, y: window.frame.height - point.y),
                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                                               pressure: 0),
              let cgEvent = pointer.cgEvent?.copy() else { return nil }
        cgEvent.type = .scrollWheel
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: delta.y)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: delta.x)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta.y))
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(delta.x))
        let cgPhase: CGScrollPhase = switch phase {
        case .began: .began
        case .ended: .ended
        case .cancelled: .cancelled
        default: .changed
        }
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgPhase.rawValue))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        // Not in the SDK's list: what `isDirectionInvertedFromDevice` reads.
        cgEvent.setIntegerValueField(CGEventField(rawValue: 137)!, value: 1)
        return NSEvent(cgEvent: cgEvent)
    }

    /// One scroll event, `fingers` being how far the fingers moved (right and down positive). Made as
    /// with natural scrolling (macOS's default), where the deltas go the fingers' way.
    private static func post(_ phase: NSEvent.Phase, fingers: CGVector, at point: CGPoint, in window: NSWindow) throws {
        let delta = (x: Int64(fingers.dx.rounded()), y: Int64(fingers.dy.rounded()))
        guard let event = scrollEvent(phase, delta: delta, at: point, in: window), event.window === window,
              event.phase == phase, event.isDirectionInvertedFromDevice else {
            throw DevBridgeFailure("Couldn't make a scroll event in the window")
        }
        NSApp.postEvent(event, atStart: false)
    }

    /// Lets the app take the events posted so far, as a frame's worth of trackpad time passes.
    private static func pause(_ duration: Duration = .milliseconds(8)) async {
        try? await Task.sleep(for: duration)
    }

    /// Fingers down at `point`, unless a held gesture carries on (from wherever it began).
    static func begin(at point: CGPoint, in window: NSWindow) async throws {
        if held != nil { try await end(cancelled: true) }
        try post(.began, fingers: .zero, at: point, in: window)
        held = (window, point)
        await pause()
    }

    /// Moves the held gesture's fingers by `fingers`, in steps of at most `step` points.
    static func move(_ fingers: CGVector, step: CGFloat = 12) async throws {
        guard let held else { throw DevBridgeFailure("No gesture under way") }
        let steps = max(Int((max(abs(fingers.dx), abs(fingers.dy)) / step).rounded(.up)), 1)
        var sent = CGVector.zero
        for index in 1...steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            let next = CGVector(dx: (fingers.dx * fraction).rounded(), dy: (fingers.dy * fraction).rounded())
            let delta = CGVector(dx: next.dx - sent.dx, dy: next.dy - sent.dy)
            sent = next
            if delta == .zero { continue }
            try post(.changed, fingers: delta, at: held.point, in: held.window)
            await pause()
        }
    }

    /// Fingers lifted (or the gesture cancelled). Waits long enough first that the lift carries no
    /// speed, so where it ends alone decides what happens.
    static func end(cancelled: Bool, stillFor: Duration = .milliseconds(150)) async throws {
        guard let held else { return }
        await pause(stillFor)
        try post(cancelled ? .cancelled : .ended, fingers: .zero, at: held.point, in: held.window)
        self.held = nil
        await pause()
    }

    /// The pointer moved to `point`, for whatever follows it (the sidebar peeking out at the left edge).
    static func movePointer(to point: CGPoint, in window: NSWindow) async throws {
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: point.x, y: window.frame.height - point.y),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { throw DevBridgeFailure("Couldn't make a pointer event") }
        NSApp.postEvent(event, atStart: false)
        await pause()
    }
}
#endif
