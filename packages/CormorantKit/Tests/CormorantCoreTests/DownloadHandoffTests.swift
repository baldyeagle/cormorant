import Testing
@testable import CormorantCore

@Suite struct DownloadHandoffTests {
    @Test func byMIMEType() {
        #expect(DownloadHandoff(mimeType: "application/vnd.apple.pkpass", filename: "ticket") == .walletPass)
        #expect(DownloadHandoff(mimeType: "text/calendar; charset=utf-8", filename: "invite") == .calendar)
        #expect(DownloadHandoff(mimeType: "Model/VND.USDZ+ZIP", filename: "chair") == .arModel)
        #expect(DownloadHandoff(mimeType: "model/vnd.reality", filename: "scene") == .arModel)
    }

    @Test func byExtensionWhenTheTypeSaysNothing() {
        #expect(DownloadHandoff(mimeType: "application/octet-stream", filename: "Boarding.PKPASS") == .walletPass)
        #expect(DownloadHandoff(mimeType: nil, filename: "event.ics") == .calendar)
        #expect(DownloadHandoff(mimeType: "application/octet-stream", filename: "chair.usdz") == .arModel)
        #expect(DownloadHandoff(mimeType: "application/octet-stream", filename: "scene.reality") == .arModel)
    }

    @Test func everythingElseIsADownload() {
        #expect(DownloadHandoff(mimeType: "application/zip", filename: "archive.zip") == nil)
        #expect(DownloadHandoff(mimeType: "model/gltf-binary", filename: "chair.glb") == nil)
        #expect(DownloadHandoff(mimeType: nil, filename: "usdz") == nil)
        // A page, whatever its address ends in.
        #expect(DownloadHandoff(mimeType: "text/html; charset=utf-8", filename: "events.ics") == nil)
        #expect(DownloadHandoff(mimeType: "application/xhtml+xml", filename: "ticket.pkpass") == nil)
    }

    @Test func attachments() {
        #expect(DownloadHandoff.isAttachment(contentDisposition: "attachment; filename=\"a.txt\""))
        #expect(DownloadHandoff.isAttachment(contentDisposition: "  Attachment"))
        #expect(!DownloadHandoff.isAttachment(contentDisposition: "inline; filename=\"a.pdf\""))
        #expect(!DownloadHandoff.isAttachment(contentDisposition: nil))
    }
}
