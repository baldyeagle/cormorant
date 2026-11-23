import QuickLook
import SwiftUI
import UIKit

/// Every download, newest first: progress and Cancel while one runs, Try Again after one fails, and a
/// finished one opens in Quick Look (whose share button saves it elsewhere or opens it in an app).
/// The files live in On My iPhone › Cormorant, which Show in Files opens.
struct DownloadsView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var previewed: URL?

    private var downloads: DownloadCenter { store.downloads }

    var body: some View {
        NavigationStack {
            List {
                ForEach(downloads.listed) { item in
                    DownloadRow(item: item, open: { previewed = item.fileURL },
                                cancel: { downloads.cancel(item.id) }, retry: { downloads.retry(item.id) })
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { downloads.delete(item.id) }
                        }
                        .contextMenu {
                            if item.status == .finished {
                                ShareLink(item: item.fileURL)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { downloads.delete(item.id) }
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if downloads.listed.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Files you download appear here and in the Files app."))
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let files = downloads.filesAppURL {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Show in Files", systemImage: "folder") { openURL(files) }
                    }
                }
            }
        }
        .quickLookPreview($previewed, in: downloads.listed.filter { $0.status == .finished }.map(\.fileURL))
        .onAppear { downloads.reload() }
    }
}

private struct DownloadRow: View {
    let item: DownloadCenter.Item
    let open: () -> Void
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.middle)
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture { if item.status == .finished { open() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.status == .finished ? .isButton : [])
        .accessibilityAction(named: "Open") { if item.status == .finished { open() } }
        .accessibilityIdentifier("Download.\(item.filename)")
    }

    @ViewBuilder private var detail: some View {
        switch item.status {
        case .downloading:
            if let fraction = item.fraction {
                Text("\(Self.size(item.receivedBytes)) of \(Self.size(item.expectedBytes))")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                Text(item.receivedBytes > 0 ? "\(Self.size(item.receivedBytes))" : "Starting…")
            }
        case .finished:
            Text([Self.size(item.receivedBytes), item.sourceURL?.displayHost].compactMap { $0 }.joined(separator: " · "))
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .downloading:
            HStack(spacing: 10) {
                if let fraction = item.fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
                Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
        case .failed where item.canRetry:
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        case .failed, .finished:
            EmptyView()
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
