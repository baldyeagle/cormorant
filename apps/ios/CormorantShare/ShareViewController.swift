import CormorantCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives a shared URL, drops it in the app-group inbox, and hands off to the main app. With more
/// than one Space it first asks which one the link opens in (`SpacePickerView`); with one it asks
/// nothing.
final class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { await handOff() }
    }

    private func handOff() async {
        guard let url = await sharedURL() else {
            await showBriefly(title: "No link found", message: "Cormorant opens web links.")
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        var spaceID: UUID?
        if let summary = SpacesSummaryFile(appGroup: AppGroup.identifier)?.read(), summary.hasSpacesToChoose {
            switch await chooseSpace(for: url, in: summary) {
            case .open(let picked): spaceID = picked
            case .cancel:
                extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                return
            }
        }
        openContainingApp(Self.openAppURL(handingOff: url, spaceID: spaceID))
        // The open above isn't a supported API and may do nothing; the link is in the inbox either way.
        extensionContext?.completeRequest(returningItems: nil)
    }

    private enum Choice {
        /// With the Space picked; nil if none was.
        case open(UUID?)
        case cancel
    }

    /// Shows the Space picker over the share sheet until Open or Cancel. The Spaces come from the
    /// summary the app writes for this (`SpacesSummaryFile`), read-only: the extension never reads or
    /// writes the app's tabs.
    private func chooseSpace(for url: URL, in summary: SpacesSummary) async -> Choice {
        let focus = UserDefaults(suiteName: AppGroup.identifier).flatMap(FocusFilterSpace.read(from:))
        guard let defaultSpace = summary.defaultSpace(focusSpace: focus) else { return .open(nil) }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Choice) -> Void = { choice in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: choice)
            }
            let picker = SpacePickerView(
                link: url, title: sharedTitle(for: url), summary: summary, defaultSpace: defaultSpace,
                focusChoseDefault: focus == defaultSpace.id,
                onOpen: { finish(.open($0)) }, onCancel: { finish(.cancel) })
            let host = UIHostingController(rootView: picker)
            // Open or Cancel, not a swipe: a swipe would leave the share request unanswered.
            isModalInPresentation = true
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    /// The page's title, when the sharing app gave one that isn't just the link.
    private func sharedTitle(for url: URL) -> String? {
        let item = extensionContext?.inputItems.lazy.compactMap { $0 as? NSExtensionItem }.first
        let title = (item?.attributedTitle ?? item?.attributedContentText)?.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty, title != url.absoluteString, URL(string: title)?.host() == nil else { return nil }
        return title
    }

    /// `cormorant://open` drains the inbox. If the inbox can't be written, the URL (and the Space picked
    /// for it) rides along instead.
    private static func openAppURL(handingOff url: URL, spaceID: UUID?) -> URL {
        var components = URLComponents()
        components.scheme = "cormorant"
        components.host = "open"
        do {
            guard let inbox = SharedInbox(appGroup: AppGroup.identifier) else { throw CocoaError(.fileNoSuchFile) }
            try inbox.append(OpenRequest(url: url, spaceID: spaceID))
        } catch {
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
                + (spaceID.map { [URLQueryItem(name: "space", value: $0.uuidString)] } ?? [])
        }
        return components.url!
    }

    /// First http(s) URL among the attachments, falling back to a URL inside shared text.
    private func sharedURL() async -> URL? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await provider.loadSharedURL(), url.isWeb { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await provider.loadSharedText(), let url = Self.firstURL(in: text) { return url }
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).lazy.compactMap(\.url).first(where: \.isWeb)
    }

    private func showBriefly(title: String, message: String) async {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        try? await Task.sleep(for: .seconds(1.5))
        guard alert.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            alert.dismiss(animated: true) { continuation.resume() }
        }
    }

    /// Extensions can't reach `UIApplication.shared`; walk the responder chain to the app object instead.
    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}

private extension NSItemProvider {
    /// `loadItem` calls back on an arbitrary queue, so these stay nonisolated and convert to a
    /// Sendable value before resuming.
    nonisolated func loadSharedURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url: URL? = switch item {
                case let url as URL: url
                case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
                case let string as String: URL(string: string)
                default: nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    nonisolated func loadSharedText() async -> String? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String? = switch item {
                case let string as String: string
                case let data as Data: String(data: data, encoding: .utf8)
                case let url as URL: url.absoluteString
                default: nil
                }
                continuation.resume(returning: text)
            }
        }
    }
}

private extension URL {
    var isWeb: Bool { ["http", "https"].contains(scheme?.lowercased() ?? "") }
}
