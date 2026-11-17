import Foundation
import Testing
import UIKit
@testable import Cormorant

extension AppTests {
    /// Paste and Go / Paste and Search, as the search panel offers them (`SearchSheet.offerPaste`):
    /// the edit menu's item is named for what was copied (`PasteAndGo.command`, from the system's
    /// pattern detection), and choosing it (`PasteAndGo.paste()`) submits the copied text on one line
    /// and closes the panel. Searching tabs only, neither is offered. The menu itself (the item comes
    /// last, after AutoFill) is CormorantUITests' PasteAndGoTests.
    ///
    /// The test host is the app, so reading what it copied asks no permission.
    @Suite("Paste and Go")
    @MainActor
    struct PasteAndGoTests {
        private static let page = """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <title>Fixture</title>
            <h1 id="path">Path</h1>
            <p id="query"></p>
            <script>
              document.getElementById('path').textContent = 'Path ' + location.pathname;
              const query = new URLSearchParams(location.search).get('q');
              if (query) document.getElementById('query').textContent = 'Query ' + query;
            </script>
            """

        @Test func pasteAndSearchSearchesCopiedText() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser(searchEngine: server.url.absoluteString + "search?q={query}")
            defer { browser.close() }
            let panel = Panel(browser)
            defer { panel.close() }

            // An address first, so the item is seen to change once the text is told apart.
            try await panel.copy(server.url.appending(path: "address").absoluteString, offering: "Paste and Go")
            try await panel.copy("cormorant\nbird facts", offering: "Paste and Search")
            PasteAndGo.paste()

            try await browser.waitForPage("/search")
            #expect(try await browser.evaluate("document.getElementById('query').textContent") == "Query cormorant bird facts",
                    "Paste and Search didn't search for the copied text")
            #expect(panel.dismissals == 1, "the panel didn't close")
            withExtendedLifetime(server) {}
        }

        /// Copied as text, without a scheme, an address is still told from a search.
        @Test func pasteAndGoTellsAnAddressInText() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            let panel = Panel(browser)
            defer { panel.close() }

            try await panel.copy("cormorant bird facts", offering: "Paste and Search")
            try await panel.copy("127.0.0.1:\(server.url.port!)/text", offering: "Paste and Go")
            PasteAndGo.paste()

            try await browser.waitForPage("/text")
            #expect(panel.dismissals == 1, "the panel didn't close")
            withExtendedLifetime(server) {}
        }

        /// Searching open tabs only, Return picks a tab, so neither item is offered; back to searching
        /// everything (the Tabs token), Paste and Go is, and loads in the tab on screen.
        @Test func searchTabsOffersNeither() async throws {
            let server = try FixtureServer(html: Self.page)
            let browser = try await TestBrowser()
            defer { browser.close() }
            try await browser.open(server.url.appending(path: "open"))
            let panel = Panel(browser)
            defer { panel.close() }
            try await panel.copy(server.url.appending(path: "pasted").absoluteString, offering: "Paste and Go")

            browser.store.searchTabs()
            panel.searchingChanged()
            #expect(UIPasteboard.general.hasStrings)
            #expect(PasteAndGo.command == nil, "\(PasteAndGo.command?.title ?? "") offered searching tabs")

            browser.store.stopSearchingTabs()
            panel.searchingChanged()
            #expect(PasteAndGo.command?.title == "Paste and Go", "Paste and Go not offered back to searching everything")
            PasteAndGo.paste()
            try await browser.waitForPage("/pasted")
            #expect(browser.store.tabs.count == 1, "Paste and Go opened a tab")
            withExtendedLifetime(server) {}
        }

        /// The search panel's part in Paste and Go, for one test: the panel offers it as it opens, and again
        /// when Search Tabs comes or goes (`SearchSheet`'s `onChange(of: isTabSearch)`). Counts the times
        /// it was told to close.
        @MainActor
        private final class Panel {
            private let browser: TestBrowser
            private let owner = UUID()
            private(set) var dismissals = 0

            init(_ browser: TestBrowser) {
                self.browser = browser
            }

            /// Copies `text`, as another app would, opens the panel, and waits until the edit menu's item is
            /// `title`: the system's pattern detection answers a moment later.
            func copy(_ text: String, offering title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
                UIPasteboard.general.string = text
                searchingChanged()
                try await browser.until("the edit menu to offer \(title) for \(text) (it offers \(PasteAndGo.command?.title ?? "nothing"))",
                                        sourceLocation: sourceLocation) {
                    PasteAndGo.command?.title == title
                }
            }

            /// The panel opened, or Search Tabs came or went.
            func searchingChanged() {
                SearchSheet.offerPaste(owner: owner, store: browser.store) { [weak self] in self?.dismissals += 1 }
            }

            /// The panel went away.
            func close() {
                PasteAndGo.release(owner)
            }
        }
    }
}
