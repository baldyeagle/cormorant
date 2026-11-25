import SwiftUI
import WebKit

/// Find on page, in the page's top corner: each search selects the next match, wrapping around.
struct FindBar: View {
    static let width: CGFloat = 300

    let webView: WKWebView
    let commands: WindowCommands
    @State private var text = ""
    @State private var notFound = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand(perform: close)
            if notFound {
                Text("Not found")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button("Previous", systemImage: "chevron.up") { find(backwards: true) }
            Button("Next", systemImage: "chevron.down") { find(backwards: false) }
            Button("Done", systemImage: "xmark", action: close)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: Self.width, height: 34)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10).fill(surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onAppear { focused = true }
        .onChange(of: commands.findRequest) { _, request in
            if let backwards = request.backwards { find(backwards: backwards) } else { focused = true }
        }
        .onChange(of: text) { notFound = false }
    }

    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.129).opacity(0.94)
            : Color(red: 0.988, green: 0.988, blue: 0.992).opacity(0.94)
    }

    private func find(backwards: Bool) {
        guard !text.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let searched = text
        Task {
            let found = (try? await webView.find(searched, configuration: configuration))?.matchFound ?? false
            if text == searched { notFound = !found }
        }
    }

    private func close() {
        commands.isFinding = false
    }
}
