import CormorantCore
import Foundation
import OSLog
import PassKit

/// A Wallet pass a page handed over, for the Add to Wallet sheet.
struct WalletPassRequest: Identifiable {
    let id = UUID()
    let pass: PKPass
}

/// The events of a calendar file a page handed over, for the New Event editor.
struct CalendarImport: Identifiable {
    let id = UUID()
    let filename: String
    let events: [CalendarEvent]
}

extension BrowserStore {
    /// Toasts for downloads: started (Show opens the list), finished (Open shows it in Quick Look),
    /// failed; passes, calendar files and AR models go to their system viewers.
    func downloadDidChange(_ event: DownloadCenter.Event) {
        switch event {
        case .started(let item) where item.handoff == .arModel:
            showToast(Toast(icon: .symbol("arkit"), message: "Loading \(item.filename)", actions: []))
        case .started(let item):
            showToast(Toast(icon: .symbol("arrow.down.circle"), message: "Downloading \(item.filename)",
                            actions: [Toast.Action("Show") { [weak self] in self?.showsDownloads = true }]))
        case .finished(let item):
            showDownloaded(item)
        case .failed(let item):
            showToast(Toast(icon: .symbol("exclamationmark.circle"), message: "Couldn't download \(item.filename)",
                            actions: [Toast.Action("Show") { [weak self] in self?.showsDownloads = true }]))
        case .handoff(let item):
            handOff(item)
        }
    }

    private func showDownloaded(_ item: DownloadCenter.Item) {
        showToast(Toast(icon: .symbol("checkmark.circle"), message: "Downloaded \(item.filename)",
                        actions: [Toast.Action("Open") { [weak self] in self?.previewedDownload = item.fileURL }]))
    }

    /// Opens a pass or calendar file in its sheet, an AR model in Quick Look (AR on a device that has
    /// it, the model on its own elsewhere); one the sheet can't take (a pass Wallet rejects, a file
    /// with no events) is kept as a download instead, so nothing the page sent is lost.
    private func handOff(_ item: DownloadCenter.Item) {
        if item.handoff == .arModel {
            // Discarded once Quick Look closes (`previewedModel`).
            if toast?.message == "Loading \(item.filename)" { dismissToast() }
            previewedModel = item.fileURL
            return
        }
        defer { downloads.discard(item) }
        switch item.handoff {
        case .walletPass:
            if platform.canAddPasses, let data = try? Data(contentsOf: item.fileURL) {
                do {
                    walletPassRequest = WalletPassRequest(pass: try PKPass(data: data))
                    return
                } catch {
                    Logger.app.notice("Wallet pass rejected: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .calendar:
            // Capped: a subscription feed can be megabytes, more than anyone adds an event at a time.
            if let size = try? item.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
               let data = try? Data(contentsOf: item.fileURL),
               let text = CalendarFile.text(from: data) {
                let events = CalendarFile.events(in: text)
                if !events.isEmpty {
                    calendarImport = CalendarImport(filename: item.filename, events: events)
                    return
                }
            }
        case .arModel, nil:
            break
        }
        if let kept = downloads.keep(item) { showDownloaded(kept) }
    }
}
