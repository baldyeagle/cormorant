import CormorantCore
import UIKit
import UniformTypeIdentifiers

/// Receives a shared URL, drops it in the app-group inbox, and hands off to the main app.
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
        openContainingApp(Self.openAppURL(handingOff: url))
        // The open above isn't a supported API and may do nothing; the link is in the inbox either way.
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// `cormorant://open` drains the inbox. If the inbox can't be written, the URL rides along instead.
    private static func openAppURL(handingOff url: URL) -> URL {
        var components = URLComponents()
        components.scheme = "cormorant"
        components.host = "open"
        do {
            guard let inbox = SharedInbox(appGroup: AppGroup.identifier) else { throw CocoaError(.fileNoSuchFile) }
            try inbox.append(OpenRequest(url: url))
        } catch {
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
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
