import CormorantCore
import CormorantTestSupport
import Foundation
import Testing
import WebKit
@testable import Cormorant

extension AppTests {
    /// Downloads: what WebKit can't show, what the server says to save (`Content-Disposition:
    /// attachment`), `<a download>` and the link menu's Download Linked File land in the browser's
    /// Downloads folder (the run's own here), with a toast, and the page stays where it was. Wallet
    /// passes, calendar files and AR models go to their system viewers instead, or are kept as
    /// downloads when the viewer can't take them. The toast coming up, the Downloads list and Quick
    /// Look showing a file stay in CormorantUITests' DownloadsTests.
    @Suite("Downloads")
    @MainActor
    struct DownloadsTests {
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <script>document.getElementById('path').textContent = 'Path ' + location.pathname</script>
            <a href="/files/archive.zip">Zip file</a>
            <a href="/files/notes">Attached notes</a>
            <a href="/saved" download="saved.html">Download attribute</a>
            <a href="/files/archive.zip" target="_blank">Zip in a new tab</a>
            <a href="/next">Next page</a>
            <a href="/invite.ics">One event</a>
            <a href="/series.ics">Two events</a>
            <a href="/empty.ics">No events</a>
            <a href="/ticket.pkpass">Broken pass</a>
            <a rel="ar" href="/chair.usdz">View in AR</a>
            """

        private static let calendar = "text/calendar; charset=utf-8"

        private static let files: [String: FixtureServer.File] = [
            "/invite.ics": .init(contentType: calendar, body: Data("""
                BEGIN:VCALENDAR\r
                BEGIN:VEVENT\r
                SUMMARY:Cormorant launch party\r
                DTSTART:20261201T180000Z\r
                DTEND:20261201T200000Z\r
                LOCATION:The boathouse\r
                END:VEVENT\r
                END:VCALENDAR\r
                """.utf8)),
            "/series.ics": .init(contentType: calendar, body: Data("""
                BEGIN:VCALENDAR
                BEGIN:VEVENT
                SUMMARY:Planning
                DTSTART:20261202T150000Z
                END:VEVENT
                BEGIN:VEVENT
                SUMMARY:Retro
                DTSTART;VALUE=DATE:20261203
                END:VEVENT
                END:VCALENDAR
                """.utf8)),
            "/empty.ics": .init(contentType: calendar, body: Data("BEGIN:VCALENDAR\nEND:VCALENDAR\n".utf8)),
            "/ticket.pkpass": .init(contentType: "application/vnd.apple.pkpass", body: Data("not a signed pass".utf8)),
            "/chair.usdz": .init(contentType: "model/vnd.usdz+zip", body: Data("PK\u{3}\u{4} not really a model".utf8)),
            "/files/archive.zip": .init(contentType: "application/zip", body: Data("PK\u{3}\u{4} not really a zip".utf8)),
            "/files/notes": .init(contentType: "text/plain; charset=utf-8", body: Data("Hello from the notes".utf8),
                                  headers: ["Content-Disposition": "attachment; filename=\"Meeting notes.txt\""]),
        ]

        @Test func fileWebKitCantShowIsDownloaded() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("Zip file")

            let item = try await finished("archive.zip", in: browser, server: server)
            #expect(try Data(contentsOf: item.fileURL) == Data("PK\u{3}\u{4} not really a zip".utf8))
            #expect(item.fileURL.deletingLastPathComponent().standardizedFileURL
                    == browser.store.downloads.directory.standardizedFileURL, "not in Downloads")
            #expect(try await heading(in: browser) == "Path /", "the page didn't stay")
            // The finished toast's Open shows it in Quick Look.
            let toast = try #require(browser.store.toast)
            #expect(toast.message == "Downloaded archive.zip")
            try #require(toast.allActions.first { $0.title == "Open" }).perform()
            #expect(browser.store.previewedDownload == item.fileURL)
            withExtendedLifetime(server) {}
        }

        /// Text WebKit could show, but the server says to save it, under the name it gives.
        @Test func attachmentIsDownloadedUnderItsName() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("Attached notes")

            let item = try await finished("Meeting notes.txt", in: browser, server: server)
            #expect(try String(contentsOf: item.fileURL, encoding: .utf8) == "Hello from the notes")
            #expect(try await heading(in: browser) == "Path /", "the attachment was shown as a page")
            withExtendedLifetime(server) {}
        }

        /// `<a download>` saves even a page WebKit would show.
        @Test func downloadAttributeSaves() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("Download attribute")

            _ = try await finished("saved.html", in: browser, server: server)
            #expect(try await heading(in: browser) == "Path /", "the page navigated instead")
            withExtendedLifetime(server) {}
        }

        /// A second download of the same name doesn't replace the first.
        @Test func sameNameIsNumbered() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("Zip file")
            _ = try await finished("archive.zip", in: browser, server: server)
            try await browser.follow("Zip file")
            _ = try await finished("archive (2).zip", in: browser, server: server)
            #expect(browser.store.downloads.listed.count == 2)
            withExtendedLifetime(server) {}
        }

        /// A tab a page opened only for a download goes again, rather than staying blank.
        @Test func downloadInANewTabClosesIt() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }
            let opener = try #require(browser.store.activeSession)

            try await browser.follow("Zip in a new tab")

            _ = try await finished("archive.zip", in: browser, server: server)
            try await browser.until("the blank tab to close (\(browser.store.tabs.count) open)") {
                browser.store.tabs.count == 1
            }
            #expect(browser.store.activeSession === opener, "didn't land back on the page")
            #expect(browser.store.state.archived.isEmpty, "the download's tab was archived")
            withExtendedLifetime(server) {}
        }

        @Test func downloadLinkedFileFromTheLinkMenu() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }
            let session = try #require(browser.store.activeSession)
            let next = server.url.appending(path: "next")

            let actions = session.linkMenuActions(for: next, kind: TabSession.linkKind(for: next))
            try #require(actions.pass.first { $0.title == "Download Linked File" }, "no Download Linked File").perform()
            session.linkMenuDidEnd(for: next)

            try await browser.until("next to be downloaded; \(server.requestLog)") {
                browser.store.downloads.listed.contains { $0.filename.hasPrefix("next") && $0.status == .finished }
            }
            #expect(try await heading(in: browser) == "Path /", "the page navigated instead")
            withExtendedLifetime(server) {}
        }

        /// The folder is the list: what's in it is listed after a relaunch, and deleting one deletes its file.
        @Test func downloadsAreListedAfterARelaunchAndDeleteTheirFile() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }
            try await browser.follow("Attached notes")
            _ = try await finished("Meeting notes.txt", in: browser, server: server)

            try await browser.relaunch()

            let item = try #require(browser.store.downloads.listed.first { $0.filename == "Meeting notes.txt" },
                                    "not listed after a relaunch")
            #expect(item.status == .finished)
            browser.store.downloads.delete(item.id)
            #expect(browser.store.downloads.listed.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: item.fileURL.path), "the file stayed")
            withExtendedLifetime(server) {}
        }

        /// A download that fails before it has a file (nothing listening) sits beside an earlier one
        /// of the same name: both stay listed once each, and deleting the finished one deletes it.
        @Test func failedDownloadBesideAFileOfItsNameIsListedOnce() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }
            let session = try #require(browser.store.activeSession)
            try await browser.follow("Zip file")
            let finishedItem = try await finished("archive.zip", in: browser, server: server)

            // Port 1: refused at once, before any response names the file.
            let refused = URL(string: "http://127.0.0.1:1/files/archive.zip")!
            session.downloadLinkedFile(refused)
            let downloads = browser.store.downloads
            try await browser.until("the refused download to fail (\(downloads.listed.map(\.status)))") {
                downloads.listed.contains { if case .failed = $0.status { true } else { false } }
            }
            downloads.reload()

            #expect(downloads.listed.count == 2, "\(downloads.listed.map { ($0.filename, $0.status) })")
            #expect(Set(downloads.listed.map(\.id)).count == downloads.listed.count, "an item listed twice")
            downloads.delete(finishedItem.id)
            #expect(!FileManager.default.fileExists(atPath: finishedItem.fileURL.path), "deleted the wrong one")
            #expect(downloads.listed.count == 1)
            withExtendedLifetime(server) {}
        }

        /// What a download the app was killed during left behind isn't a download: not listed, and gone.
        @Test func halfWrittenFileFromAKilledRunIsNotListed() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }
            let incoming = browser.store.downloads.directory.appending(path: ".incoming/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            try Data("half a zip".utf8).write(to: incoming.appending(path: "big.zip"))

            try await browser.relaunch()

            #expect(browser.store.downloads.listed.isEmpty, "\(browser.store.downloads.listed.map(\.filename))")
            #expect(!FileManager.default.fileExists(atPath: incoming.path), "the partial file stayed")
            withExtendedLifetime(server) {}
        }

        // MARK: Wallet passes, calendar files, AR models

        /// One event, for the New Event editor; nothing lands in Downloads.
        @Test func calendarFileWithOneEventGoesToTheEditor() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("One event")

            try await browser.until("the event to be handed over; \(server.requestLog)") { browser.store.calendarImport != nil }
            let events = try #require(browser.store.calendarImport).events
            #expect(events.map(\.title) == ["Cormorant launch party"])
            #expect(events.first?.location == "The boathouse")
            #expect(browser.store.downloads.listed.isEmpty, "a calendar file was kept as a download")
            #expect(browser.store.toast == nil, "a calendar file got a download toast")
            withExtendedLifetime(server) {}
        }

        @Test func calendarFileWithSeveralEventsListsThem() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("Two events")

            try await browser.until("the events to be handed over; \(server.requestLog)") { browser.store.calendarImport != nil }
            let events = try #require(browser.store.calendarImport).events
            #expect(events.map(\.title) == ["Planning", "Retro"])
            #expect(events.map(\.isAllDay) == [false, true])
            withExtendedLifetime(server) {}
        }

        /// Nothing to add: kept as a download rather than lost.
        @Test func calendarFileWithNoEventsIsKept() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("No events")

            _ = try await finished("empty.ics", in: browser, server: server)
            #expect(browser.store.calendarImport == nil)
            #expect(browser.store.toast?.message == "Downloaded empty.ics")
            withExtendedLifetime(server) {}
        }

        /// Wallet won't take an unsigned pass: kept as a download rather than lost.
        @Test func passWalletRejectsIsKept() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("Broken pass")

            _ = try await finished("ticket.pkpass", in: browser, server: server)
            #expect(browser.store.walletPassRequest == nil)
            withExtendedLifetime(server) {}
        }

        /// A page's "View in AR" link: the model goes to Quick Look, not Downloads, and is thrown away
        /// once Quick Look closes.
        @Test func arModelOpensInQuickLook() async throws {
            let (server, browser) = try await start()
            defer { browser.close() }

            try await browser.follow("View in AR")

            try await browser.until("the model to be handed to Quick Look; \(server.requestLog)") {
                browser.store.previewedModel != nil
            }
            let file = try #require(browser.store.previewedModel)
            #expect(file.lastPathComponent == "chair.usdz")
            #expect(try Data(contentsOf: file) == Data("PK\u{3}\u{4} not really a model".utf8))
            #expect(browser.store.downloads.listed.isEmpty, "the model was kept as a download")
            #expect(try await heading(in: browser) == "Path /", "the page navigated")

            browser.store.previewedModel = nil
            #expect(!FileManager.default.fileExists(atPath: file.path), "the model stayed once Quick Look closed")
            withExtendedLifetime(server) {}
        }

        // MARK: Helpers

        private func start() async throws -> (FixtureServer, TestBrowser) {
            let server = try FixtureServer(html: Self.page, files: Self.files)
            let browser = try await TestBrowser()
            try await browser.open(server.url)
            return (server, browser)
        }

        /// Waits for `filename` to be listed, finished, and returns it.
        private func finished(_ filename: String, in browser: TestBrowser, server: FixtureServer,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws -> DownloadCenter.Item {
            let downloads = browser.store.downloads
            try await browser.until("\(filename) to download (listed: \(downloads.listed.map(\.filename))); \(server.requestLog)",
                                    sourceLocation: sourceLocation) {
                downloads.listed.contains { $0.filename == filename && $0.status == .finished }
            }
            return try #require(downloads.listed.first { $0.filename == filename }, sourceLocation: sourceLocation)
        }

        private func heading(in browser: TestBrowser) async throws -> String? {
            try await browser.evaluate("document.getElementById('path').textContent")
        }
    }
}
