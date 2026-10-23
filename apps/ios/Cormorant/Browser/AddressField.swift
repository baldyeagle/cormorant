import SwiftUI

/// Shows the host at rest and the full URL while editing. Escape or Cancel restores the previous text.
struct AddressField: View {
    let url: URL?
    let isLoading: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: (String) -> Void
    let onReloadOrStop: () -> Void

    @State private var text = ""
    @State private var selection: TextSelection?

    private var restingText: String { url?.displayHost ?? "" }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search or enter address", text: $text, selection: $selection)
                .focused(isFocused)
                .keyboardType(.webSearch)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .multilineTextAlignment(isFocused.wrappedValue ? .leading : .center)
                .onSubmit {
                    onSubmit(text)
                    isFocused.wrappedValue = false
                }
                .onKeyPress(.escape) {
                    isFocused.wrappedValue = false
                    return .handled
                }

            if isFocused.wrappedValue {
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
            } else if url != nil {
                Button(isLoading ? "Stop" : "Reload",
                       systemImage: isLoading ? "xmark" : "arrow.clockwise",
                       action: onReloadOrStop)
                    .imageScale(.medium)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onAppear { text = restingText }
        .onChange(of: url) {
            if !isFocused.wrappedValue { text = restingText }
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
            if focused {
                text = url?.absoluteString ?? ""
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else {
                text = restingText
                selection = nil
            }
        }
    }
}
