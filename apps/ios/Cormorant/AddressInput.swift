import Foundation

/// Turns address-bar text into a URL: navigate if it looks like one, otherwise search.
enum AddressInput {
    static func url(for rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file"].contains(scheme) {
            return url
        }

        if looksLikeHost(input), let url = URL(string: "https://\(input)"), url.host() != nil {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        if hostOnly == "localhost" { return true }
        let labels = hostOnly.split(separator: ".")
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }
}
