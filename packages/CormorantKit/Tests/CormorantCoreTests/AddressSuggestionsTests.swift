import Foundation
import Testing
@testable import CormorantCore

@Suite struct AddressSuggestionsTests {
    private func page(_ string: String, _ title: String = "") -> HistoryEntry {
        let address = url(string)
        return HistoryEntry(url: address, title: title, visitCount: 1, typedCount: 0, lastVisitedAt: t0,
                            key: BrowsingHistory.key(for: address)!)
    }

    private func closed(_ string: String, _ title: String, at date: Date) -> ArchivedTab {
        ArchivedTab(url: url(string), title: title, archivedAt: date, originalCreatedAt: date)
    }

    @Test func emptyTextSuggestsNothing() {
        let suggestions = AddressSuggestions(
            text: "  ", engine: .duckDuckGo, openTabs: [Tab(url: url("https://a.example"))], archived: [],
            pages: [page("https://a.example")], pastSearches: ["a"], engineSuggestions: ["a"])
        #expect(suggestions.isEmpty)
    }

    @Test func openTabsMatchEveryWordAndHideTheirHistoryAndClosedCopies() {
        let tab = Tab(url: url("https://github.com/anthropics/claude-code"), title: "Claude Code")
        let other = Tab(url: url("https://example.com"), title: "Example")
        let suggestions = AddressSuggestions(
            text: "claude git", engine: .duckDuckGo, openTabs: [tab, other],
            archived: [closed("http://www.github.com/anthropics/claude-code/", "Claude Code", at: t0),
                       closed("https://github.com/anthropics/claude-cookbooks", "Claude Cookbooks", at: t0)],
            pages: [page("https://github.com/anthropics/claude-code#readme", "Claude Code"),
                    page("https://github.com/anthropics/claude-cookbooks", "Claude Cookbooks")],
            pastSearches: [], engineSuggestions: [])
        #expect(suggestions.openTabs == [tab])
        #expect(suggestions.pages.map(\.title) == ["Claude Cookbooks"])
        // The cookbooks page is already a history row; the code page is an open tab.
        #expect(suggestions.closed.isEmpty)
    }

    @Test func closedTabsNotInHistoryShowMostRecentFirst() {
        let suggestions = AddressSuggestions(
            text: "notes", engine: .duckDuckGo, openTabs: [],
            archived: [closed("https://a.example", "Notes A", at: t0), closed("https://b.example", "Notes B", at: t0 + hour),
                       closed("https://c.example", "Notes C", at: t0 + 2 * hour), closed("https://d.example", "Other", at: t0)],
            pages: [], pastSearches: [], engineSuggestions: [])
        #expect(suggestions.closed.map(\.title) == ["Notes C", "Notes B"])
    }

    @Test func searchesStartWithTheTypedQueryThenPastThenEngine() {
        let suggestions = AddressSuggestions(
            text: "shower", engine: .duckDuckGo, openTabs: [], archived: [], pages: [],
            pastSearches: ["shower tile", "Shower heads", "shower drain"],
            engineSuggestions: ["SHOWER", "shower heads", "shower curtain", "shower caddy", "shower door"])
        #expect(suggestions.searches == [
            SearchSuggestion(query: "shower", source: .typed),
            SearchSuggestion(query: "shower tile", source: .history),
            SearchSuggestion(query: "Shower heads", source: .history),
            SearchSuggestion(query: "shower curtain", source: .engine),
            SearchSuggestion(query: "shower caddy", source: .engine),
            SearchSuggestion(query: "shower door", source: .engine),
        ])
    }

    @Test func pastSearchesFillTheSectionWhenTheEngineHasNone() {
        let suggestions = AddressSuggestions(
            text: "sh", engine: .duckDuckGo, openTabs: [], archived: [], pages: [],
            pastSearches: ["shower tile", "shower heads", "shower drain"], engineSuggestions: [])
        #expect(suggestions.searches.map(\.source) == [.typed, .history, .history, .history])
    }

    @Test func addressesGetNoTypedSearchRow() {
        let suggestions = AddressSuggestions(
            text: "github.com", engine: .duckDuckGo, openTabs: [], archived: [], pages: [],
            pastSearches: ["github.com login"], engineSuggestions: [])
        #expect(suggestions.searches == [SearchSuggestion(query: "github.com login", source: .history)])
    }

    @Test func limits() {
        let tabs = (0..<5).map { Tab(url: url("https://example.com/\($0)"), title: "Doc \($0)") }
        let pages = (5..<12).map { page("https://example.com/\($0)", "Doc \($0)") }
        let suggestions = AddressSuggestions(
            text: "doc", engine: .duckDuckGo, openTabs: tabs, archived: [], pages: pages,
            pastSearches: [], engineSuggestions: (0..<10).map { "doc \($0)" })
        #expect(suggestions.openTabs.count == 3)
        #expect(suggestions.pages.count == 4)
        #expect(suggestions.searches.count == 9)
    }

    @Test func matching() {
        let address = url("https://www.example.com/Recipes/pasta")
        #expect(AddressSuggestions.matches("pasta", title: "", url: address))
        #expect(AddressSuggestions.matches("RECIPES example", title: "", url: address))
        #expect(AddressSuggestions.matches("https://www.exa", title: "", url: address))
        #expect(AddressSuggestions.matches("dinner", title: "Easy Dinner", url: address))
        #expect(!AddressSuggestions.matches("pasta pizza", title: "", url: address))
    }
}

@Suite struct SearchSuggestionClientTests {
    @Test func builtInEnginesOfferSuggestionsCustomOnesDont() {
        for engine in SearchEngine.builtIn {
            #expect(engine.offersSuggestions, "\(engine.name)")
            let url = engine.suggestionsURL(for: "café & crème")
            #expect(url?.scheme == "https")
            #expect(url?.absoluteString.contains("caf%C3%A9%20%26%20cr%C3%A8me") == true, "\(engine.name)")
        }
        let custom = SearchEngine(id: "custom", name: "Mine", queryTemplate: "https://search.example/?q={query}")
        #expect(!custom.offersSuggestions)
        // A custom engine reusing a built-in's id isn't trusted with its endpoint either.
        let impostor = SearchEngine(id: "google", name: "Google", queryTemplate: "https://evil.example/?q={query}")
        #expect(!impostor.offersSuggestions)
        #expect(SearchEngine.duckDuckGo.suggestionsURL(for: "   ") == nil)
    }

    @Test func onlySearchesGoToTheEngine() {
        for text in ["swift testing", "how do I use URLSession", "c++ templates", "what is 2:30 in seconds"] {
            #expect(SearchSuggestionClient.mayAsk(about: text, engine: .duckDuckGo), "\(text)")
        }
        let addresses = [
            "github.com", "intranet.corp", "nas.lan:5000/x", "192.168.1", "admin:pw@router.local",
            "http:/bank.com/a?token=1", "https://bank.com/a?token=1 hello", "me@example.com", "localhost",
            "node.js", "a/b", "   ",
        ]
        for text in addresses {
            #expect(!SearchSuggestionClient.mayAsk(about: text, engine: .duckDuckGo), "\(text)")
        }
    }

    @Test func parsesOpenSearchResponses() {
        let json = #"["sw",["swift"," Swift ","swift\ncode","",42,"swiftui"],[],{"google:suggestsubtypes":[]}]"#
        #expect(SearchSuggestionClient.parse(Data(json.utf8), limit: 8) == ["swift", "swift code", "swiftui"])
        #expect(SearchSuggestionClient.parse(Data(json.utf8), limit: 1) == ["swift"])
        let long = #"["a",[""# + String(repeating: "a", count: 201) + #"","ok"]]"#
        #expect(SearchSuggestionClient.parse(Data(long.utf8), limit: 8) == ["ok"])
        for bad in ["", "{}", "[]", #"["a"]"#, #"["a","b"]"#, "<html>"] {
            #expect(SearchSuggestionClient.parse(Data(bad.utf8), limit: 8).isEmpty, "\(bad)")
        }
    }
}
