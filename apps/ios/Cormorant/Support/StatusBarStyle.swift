import ObjectiveC
import SwiftUI
import UIKit

extension View {
    /// The status bar's style while this view is on screen: the one whose text reads on a `scheme`
    /// background, or the system's (following the appearance) for nil.
    func statusBarColorScheme(_ scheme: ColorScheme?) -> some View {
        modifier(StatusBarColorScheme(scheme: scheme))
    }
}

private struct StatusBarColorScheme: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.toolbarColorScheme(scheme, for: .statusBar)
        } else {
            content.background(LegacyStatusBarStyle(style: scheme.map { $0 == .dark ? .lightContent : .darkContent }))
        }
    }
}

/// Before iOS 27 SwiftUI can't set the status bar's style for part of a window, and UIKit asks only
/// the window's root view controller, which SwiftUI owns. So the root's `preferredStatusBarStyle` is
/// overridden, for that one instance: an associated value it returns when set, the system's when not.
private struct LegacyStatusBarStyle: UIViewRepresentable {
    let style: UIStatusBarStyle?

    func makeUIView(context: Context) -> StyleView { StyleView() }

    func updateUIView(_ view: StyleView, context: Context) { view.style = style }

    final class StyleView: UIView {
        var style: UIStatusBarStyle? {
            didSet { if style != oldValue { apply() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let root = window?.rootViewController else { return }
            RootStatusBarStyle.set(style, on: root)
        }
    }
}

@MainActor
private enum RootStatusBarStyle {
    private static var styleKey: UInt8 = 0
    private static var overriddenClasses: Set<ObjectIdentifier> = []

    static func set(_ style: UIStatusBarStyle?, on controller: UIViewController) {
        guard let controllerClass = object_getClass(controller) else { return }
        override(controllerClass)
        objc_setAssociatedObject(controller, &styleKey, style.map { NSNumber(value: $0.rawValue) },
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        controller.setNeedsStatusBarAppearanceUpdate()
    }

    /// Replaces the getter on the controller's own class (added there if it only inherits one), so
    /// other kinds of view controller are untouched; instances without a style get the original.
    private static func override(_ controllerClass: AnyClass) {
        guard overriddenClasses.insert(ObjectIdentifier(controllerClass)).inserted else { return }
        let selector = #selector(getter: UIViewController.preferredStatusBarStyle)
        guard let method = class_getInstanceMethod(controllerClass, selector) else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let replacement: @convention(block) (AnyObject) -> Int = { controller in
            if let style = objc_getAssociatedObject(controller, &styleKey) as? NSNumber { return style.intValue }
            return original(controller, selector)
        }
        let implementation = imp_implementationWithBlock(replacement)
        if !class_addMethod(controllerClass, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}
