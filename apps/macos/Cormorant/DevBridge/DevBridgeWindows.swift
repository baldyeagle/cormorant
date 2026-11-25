#if DEBUG
import AppKit
import WebKit

/// Any of the app's windows: listing them (and other processes' windows over them), clicks and keys
/// fed in-process, and their accessibility trees. Frames are in screen points from the primary screen's
/// top-left corner; points in a window are from the window's top-left corner.
enum DevBridgeWindows {
    /// The app's window numbered `number`.
    static func window(number: Int) throws -> NSWindow {
        if let window = NSApp.windows.first(where: { $0.windowNumber == number }) { return window }
        if let other = onScreen().first(where: { $0.number == number }) {
            throw DevBridgeFailure("Window \(number) is \(other.owner)'s; only this app's own windows can be drawn or driven")
        }
        throw DevBridgeFailure("No window \(number); list_windows lists them")
    }

    // MARK: Listing

    static func info(_ window: NSWindow, index: Int, isBrowser: Bool) -> [String: Any] {
        [
            "index": index, "number": window.windowNumber, "class": className(window), "title": window.title,
            "frame": json(screenRect(window.frame)), "level": window.level.rawValue,
            "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
            "unoccluded": window.occlusionState.contains(.visible), "canBecomeKey": window.canBecomeKey,
            "parent": nullable(window.parent?.windowNumber ?? window.sheetParent?.windowNumber),
            "children": window.childWindows?.map(\.windowNumber) ?? [],
            "contentView": nullable(window.contentView.map(className)),
            "remoteViews": remoteViews(in: window).map {
                ["class": $0.name, "frameInWindow": json($0.frame), "hidden": $0.hidden, "inWebView": $0.inWebView]
            },
            "browser": isBrowser,
        ]
    }

    struct ScreenWindow {
        let number: Int
        let owner: String
        let pid: Int
        let layer: Int
        let frame: CGRect
        let alpha: Double
        let name: String?
        /// Front to back, 0 frontmost.
        let order: Int
    }

    /// Every window on screen, any process's, front to back. Other apps' titles are left out without
    /// Screen Recording; their owner, place and level aren't.
    static func onScreen() -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.enumerated().compactMap { order, entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ScreenWindow(number: number, owner: entry[kCGWindowOwnerName as String] as? String ?? "?",
                                pid: entry[kCGWindowOwnerPID as String] as? Int ?? 0,
                                layer: entry[kCGWindowLayer as String] as? Int ?? 0, frame: frame,
                                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                                name: entry[kCGWindowName as String] as? String, order: order)
        }
    }

    /// Always on screen, so never a panel the app brought up.
    private static let systemChrome: Set<String> = [
        "Dock", "Window Server", "Control Center", "SystemUIServer", "loginwindow", "Notification Center", "WindowManager",
    ]

    /// A screen-wide overlay (the lock screen, Siri's), in screen points from the primary's top-left.
    private static func coversScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let area = screenRect(screen.frame)
            return frame.width >= area.width * 0.9 && frame.height >= area.height * 0.7 && frame.intersects(area)
        }
    }

    /// Windows on screen that aren't in `NSApp.windows`: this process's own that AppKit doesn't list,
    /// and (unless `all`) other processes' raised windows (panels, menus) in front of one of the app's
    /// windows and over or within 200 points of it, as a system panel next to a field would be,
    /// leaving out the Dock, menu bar, screen-wide overlays and other apps' ordinary windows.
    static func otherWindows(all: Bool) -> [[String: Any]] {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let listed = Set(NSApp.windows.map(\.windowNumber))
        let windows = onScreen()
        let ours = windows.filter { $0.pid == pid }
        return windows.compactMap { window -> [String: Any]? in
            if window.pid == pid {
                if listed.contains(window.number) { return nil }
            } else if !all {
                guard window.layer > 0, !systemChrome.contains(window.owner), !coversScreen(window.frame),
                      ours.contains(where: { $0.order > window.order && $0.frame.insetBy(dx: -200, dy: -200).intersects(window.frame) })
                else { return nil }
            }
            return ["number": window.number, "owner": window.owner, "pid": window.pid, "thisProcess": window.pid == pid,
                    "layer": window.layer, "frame": json(window.frame), "alpha": window.alpha,
                    "name": nullable(window.name), "order": window.order]
        }
    }

    /// The app's windows on screen and other processes' near them, by number: what's up before and
    /// after a click or keys, to tell what came up.
    static func shown() -> [Int: [String: Any]] {
        var shown: [Int: [String: Any]] = [:]
        for window in NSApp.windows where window.isVisible {
            shown[window.windowNumber] = ["number": window.windowNumber, "class": className(window), "level": window.level.rawValue,
                                          "frame": json(screenRect(window.frame))]
        }
        for window in otherWindows(all: false) {
            if let number = window["number"] as? Int { shown[number] = window }
        }
        return shown
    }

    /// Views drawn by another process (a view service, a remote panel): a capture from inside the app
    /// shows them blank, except in a web view, whose snapshot is pasted over them.
    static func remoteViews(in window: NSWindow) -> [(name: String, frame: CGRect, hidden: Bool, inWebView: Bool)] {
        views(in: window).compactMap { view in
            let name = className(view)
            guard ["Remote", "ViewBridge", "ViewService", "Portal", "LayerHost"].contains(where: name.contains) else { return nil }
            var ancestor = view.superview
            while let next = ancestor, !(next is WKWebView) { ancestor = next.superview }
            return (name, rect(of: view, in: window), view.isHiddenOrHasHiddenAncestor, ancestor != nil)
        }
    }

    /// Where keys go: a menu that's up (it takes the keyboard while it tracks), else the key window.
    static var keyTarget: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && className($0).contains("MenuWindow") } ?? NSApp.keyWindow
    }

    /// The web views on show in `window`.
    static func webViews(in window: NSWindow) -> [WKWebView] {
        views(in: window).compactMap { $0 as? WKWebView }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Every view in the window, the frame view down, at most 5000.
    private static func views(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView?.superview ?? window.contentView else { return [] }
        var found: [NSView] = []
        var stack = [root]
        while let view = stack.popLast(), found.count < 5000 {
            found.append(view)
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    // MARK: Pointer and keys

    /// A click at `point`, its down and up posted together so a control's tracking loop finds the up.
    static func click(at point: CGPoint, in window: NSWindow, right: Bool, count: Int, modifiers: NSEvent.ModifierFlags) async throws {
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.mouseMoved] + (1...count).flatMap({ _ in [down, up] }) {
            let clicks = type == .mouseMoved ? 0 : (events.count + 1) / 2
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: clicks, pressure: type == down ? 1 : 0),
                  event.window === window else { throw DevBridgeFailure("Couldn't make a click in the window") }
            events.append(event)
        }
        events.forEach { NSApp.postEvent($0, atStart: false) }
        try? await Task.sleep(for: .milliseconds(150))
    }

    struct Key {
        let characters: String
        let ignoringModifiers: String
        let code: UInt16
        var flags: NSEvent.ModifierFlags = []
    }

    static let namedKeys: [String: Key] = {
        func function(_ scalar: Int, _ code: UInt16) -> Key {
            let text = String(UnicodeScalar(scalar).map(Character.init) ?? " ")
            return Key(characters: text, ignoringModifiers: text, code: code, flags: [.function, .numericPad])
        }
        func plain(_ text: String, _ code: UInt16) -> Key { Key(characters: text, ignoringModifiers: text, code: code) }
        return [
            "return": plain("\r", 36), "enter": plain("\u{3}", 76), "tab": plain("\t", 48), "space": plain(" ", 49),
            "delete": plain("\u{7F}", 51), "escape": plain("\u{1B}", 53),
            "forward_delete": Key(characters: "\u{F728}", ignoringModifiers: "\u{F728}", code: 117, flags: [.function]),
            "left": function(NSLeftArrowFunctionKey, 123), "right": function(NSRightArrowFunctionKey, 124),
            "down": function(NSDownArrowFunctionKey, 125), "up": function(NSUpArrowFunctionKey, 126),
            "home": Key(characters: "\u{F729}", ignoringModifiers: "\u{F729}", code: 115, flags: [.function]),
            "end": Key(characters: "\u{F72B}", ignoringModifiers: "\u{F72B}", code: 119, flags: [.function]),
            "page_up": Key(characters: "\u{F72C}", ignoringModifiers: "\u{F72C}", code: 116, flags: [.function]),
            "page_down": Key(characters: "\u{F72D}", ignoringModifiers: "\u{F72D}", code: 121, flags: [.function]),
        ]
    }()

    /// US-layout key codes, so the text system sees the key it would from the keyboard.
    private static let codes: [Character: UInt16] = {
        var codes: [Character: UInt16] = [:]
        let rows: [(String, String, [UInt16])] = [
            ("asdfhgzxcv", "ASDFHGZXCV", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
            ("bqweryt123465=97-80]ou[ip", "BQWERYT!@#$^%+(&_*)}OU{IP", [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35]),
            ("lj'k;\\,/nm.`", "LJ\"K:|<?NM>~", [37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50]),
        ]
        for (lower, upper, keyCodes) in rows {
            for (index, code) in keyCodes.enumerated() {
                codes[Array(lower)[index]] = code
                codes[Array(upper)[index]] = code
            }
        }
        codes[" "] = 49
        return codes
    }()

    /// The key typing `character` on a US keyboard (shifted if need be); 0 for others, whose
    /// characters the text system still takes.
    static func key(typing character: Character) -> Key {
        let text = String(character)
        if character == "\n" || character == "\r\n" || character == "\r" { return namedKeys["return"]! }
        let shifted = character.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(character)
        return Key(characters: text, ignoringModifiers: text, code: codes[character] ?? 0, flags: shifted ? [.shift] : [])
    }

    /// One key, down and up, to the key window (or `window`), as the keyboard would send it.
    static func press(_ key: Key, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let flags = key.flags.union(modifiers)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: key.characters,
                                               charactersIgnoringModifiers: key.ignoringModifiers, isARepeat: false, keyCode: key.code)
            else { throw DevBridgeFailure("Couldn't make a key event") }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Makes the view at `point` (or the nearest one above it that takes it) the first responder.
    static func focus(at point: CGPoint, in window: NSWindow) throws -> NSResponder {
        guard let root = window.contentView?.superview ?? window.contentView,
              let hit = root.hitTest(NSPoint(x: point.x, y: window.frame.height - point.y)) else {
            throw DevBridgeFailure("No view at (\(point.x), \(point.y))")
        }
        var view: NSView? = hit
        while let candidate = view, !candidate.acceptsFirstResponder { view = candidate.superview }
        guard let view else { throw DevBridgeFailure("Nothing at (\(point.x), \(point.y)) takes focus (hit \(className(hit)))") }
        guard window.makeFirstResponder(view) else { throw DevBridgeFailure("\(className(view)) refused to take focus") }
        return view
    }

    /// The window's first responder: for a text field being edited, the field (not its field editor),
    /// its content type and its text (a secure field's only as a length).
    static func responder(in window: NSWindow) -> [String: Any] {
        guard let responder = window.firstResponder else { return ["class": NSNull()] }
        var result: [String: Any] = ["class": className(responder)]
        var view = responder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            result["fieldEditorFor"] = className(field)
            view = field
        }
        if let field = view as? NSTextField {
            result["identifier"] = nullable(field.identifier?.rawValue)
            result["contentType"] = nullable(field.contentType?.rawValue)
            result["placeholder"] = nullable(field.placeholderString)
            if field is NSSecureTextField {
                result["length"] = field.stringValue.count
            } else {
                result["value"] = field.stringValue
            }
        }
        if let view, view.window === window { result["frame"] = json(rect(of: view, in: window)) }
        return result
    }

    // MARK: Accessibility

    /// The window's accessibility tree as the app gives it, `depth` levels down, at most `limit` nodes.
    static func accessibilityTree(of window: NSWindow, depth: Int, limit: Int) -> (tree: [String: Any], count: Int, truncated: Bool) {
        var count = 0
        var truncated = false
        var seen = Set<ObjectIdentifier>()
        // Held so a freed element's address isn't taken for a later one's.
        var kept: [AnyObject] = []
        func node(_ element: Any, level: Int) -> [String: Any] {
            count += 1
            let object = element as AnyObject
            var result: [String: Any] = ["class": className(object)]
            guard seen.insert(ObjectIdentifier(object)).inserted else {
                result["repeat"] = true
                return result
            }
            kept.append(object)
            // Its content is in another process, and asking for it turns on the page's accessibility.
            if object is WKWebView {
                result["role"] = "AXGroup"
                result["webContent"] = "left out; page_text reads the page"
                if let view = object as? NSView { result["frame"] = json(rect(of: view, in: window)) }
                return result
            }
            if isSecure(object) {
                result["role"] = "AXTextField"
                result["subrole"] = NSAccessibility.Subrole.secureTextField.rawValue
                result["value"] = "(secure)"
                if let view = object as? NSView, view.window === window { result["frame"] = json(rect(of: view, in: window)) }
                return result
            }
            guard let element = Element(object) else { return result }
            result["role"] = nullable(element.role)
            if let subrole = element.subrole { result["subrole"] = subrole }
            for (key, text) in [("label", element.label), ("title", element.title), ("identifier", element.identifier),
                                ("placeholder", element.placeholder), ("help", element.help)] {
                if let text, !text.isEmpty { result[key] = String(text.prefix(300)) }
            }
            if element.subrole == NSAccessibility.Subrole.secureTextField.rawValue {
                result["value"] = "(secure)"
                return result
            }
            if let value = describe(element.value) {
                result["value"] = value
            }
            if element.focused { result["focused"] = true }
            if !element.enabled, let role = element.role, controlRoles.contains(role) { result["enabled"] = false }
            if let frame = element.frame, frame != .zero { result["frame"] = json(windowRect(fromScreen: frame, in: window)) }
            var children = element.children
            // SwiftUI builds its tree only for an assistive app: under it, the AppKit views it holds.
            if children.isEmpty, let view = object as? NSView {
                children = accessibleSubviews(of: view)
                if !children.isEmpty { result["childrenFromSubviews"] = true }
            }
            if !children.isEmpty {
                if level >= depth || count >= limit {
                    result["childCount"] = children.count
                    truncated = true
                } else {
                    var nodes: [[String: Any]] = []
                    for child in children {
                        guard count < limit else {
                            truncated = true
                            result["childrenLeftOut"] = children.count - nodes.count
                            break
                        }
                        nodes.append(node(child, level: level + 1))
                    }
                    result["children"] = nodes
                }
            }
            return result
        }
        let tree = node(window, level: 0)
        return withExtendedLifetime(kept) { (tree, count, truncated) }
    }

    /// A password field, or the field editor typing into one: never read or gone into.
    private static func isSecure(_ object: AnyObject) -> Bool {
        if object is NSSecureTextField { return true }
        if let editor = object as? NSTextView, editor.isFieldEditor, editor.delegate is NSSecureTextField { return true }
        if let element = object as? NSAccessibilityProtocol,
           element.accessibilitySubrole() == .secureTextField { return true }
        return false
    }

    /// The nearest views under `view` that are accessibility elements, at most 2000 looked at.
    private static func accessibleSubviews(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        var queue = view.subviews.filter { !$0.isHidden }
        var looked = 0
        while !queue.isEmpty, looked < 2000 {
            let next = queue.removeFirst()
            looked += 1
            if next.isAccessibilityElement() {
                found.append(next)
            } else {
                queue.append(contentsOf: next.subviews.filter { !$0.isHidden })
            }
        }
        return found
    }

    private static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXTextField",
        "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXLink",
    ]

    /// An accessibility element read through the NSAccessibility protocol, or for an older element
    /// (a menu's rows), through its attributes.
    private struct Element {
        var role, subrole, label, title, identifier, placeholder, help: String?
        var value: Any?
        var focused = false
        var enabled = true
        var frame: CGRect?
        var children: [Any] = []

        init?(_ object: AnyObject) {
            if let element = object as? NSAccessibilityProtocol {
                role = element.accessibilityRole()?.rawValue
                subrole = element.accessibilitySubrole()?.rawValue
                label = element.accessibilityLabel()
                title = element.accessibilityTitle()
                identifier = element.accessibilityIdentifier()
                placeholder = element.accessibilityPlaceholderValue()
                help = element.accessibilityHelp()
                value = element.accessibilityValue()
                focused = element.isAccessibilityFocused()
                enabled = element.isAccessibilityEnabled()
                frame = element.accessibilityFrame()
                children = element.accessibilityChildren() ?? []
                return
            }
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard let object = object as? NSObject, object.responds(to: selector) else { return nil }
            func attribute(_ name: String) -> Any? { object.perform(selector, with: name)?.takeUnretainedValue() }
            role = attribute("AXRole") as? String
            subrole = attribute("AXSubrole") as? String
            label = attribute("AXDescription") as? String
            title = attribute("AXTitle") as? String
            identifier = attribute("AXIdentifier") as? String
            placeholder = attribute("AXPlaceholderValue") as? String
            help = attribute("AXHelp") as? String
            value = attribute("AXValue")
            focused = (attribute("AXFocused") as? NSNumber)?.boolValue ?? false
            enabled = (attribute("AXEnabled") as? NSNumber)?.boolValue ?? true
            if let position = (attribute("AXPosition") as? NSValue)?.pointValue, let size = (attribute("AXSize") as? NSValue)?.sizeValue {
                frame = CGRect(origin: position, size: size)
            }
            children = attribute("AXChildren") as? [Any] ?? []
        }
    }

    private static func describe(_ value: Any?) -> String? {
        let text: String? = switch value {
        case nil: nil
        case let string as String: string
        case let attributed as NSAttributedString: attributed.string
        case let number as NSNumber: number.stringValue
        case let url as URL: url.absoluteString
        case let other?: "<\(className(other as AnyObject))>"
        }
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(300))
    }

    // MARK: Geometry and names

    /// `frame` (AppKit screen points, bottom-left origin) from the main screen's top-left corner.
    static func screenRect(_ frame: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// A screen frame from the window's top-left corner.
    static func windowRect(fromScreen frame: CGRect, in window: NSWindow) -> CGRect {
        CGRect(x: frame.minX - window.frame.minX, y: window.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    static func rect(of view: NSView, in window: NSWindow) -> CGRect {
        let frame = view.convert(view.bounds, to: nil)
        return CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }

    static func json(_ rect: CGRect) -> [String: Any] {
        ["x": rect.minX.rounded(), "y": rect.minY.rounded(), "width": rect.width.rounded(), "height": rect.height.rounded()]
    }

    /// The Objective-C name for AppKit's classes (`NSRemoteView`), the Swift one for the app's, never
    /// key-value observing's stand-in subclass.
    static func className(_ object: AnyObject) -> String {
        var type: AnyClass = object_getClass(object) ?? NSObject.self
        while NSStringFromClass(type).contains("NSKVONotifying_"), let original = class_getSuperclass(type) { type = original }
        let name = NSStringFromClass(type)
        return String((name.hasPrefix("_Tt") ? String(reflecting: type) : name).prefix(160))
    }
}
#endif
