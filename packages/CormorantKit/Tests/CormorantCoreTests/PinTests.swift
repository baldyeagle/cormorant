import Foundation
import Testing
@testable import CormorantCore

@Suite struct PinTests {
    /// Home with three tabs opened an hour apart; `c` is active.
    private func home() -> (BrowserState, a: Tab, b: Tab, c: Tab) {
        var state = BrowserState()
        let a = state.openTab(url: url("https://a.example/inbox"), title: "Inbox", now: t0)
        let b = state.openTab(url: url("https://b.example"), title: "B", now: t0 + hour)
        let c = state.openTab(url: url("https://c.example"), title: "C", now: t0 + 2 * hour)
        return (state, a, b, c)
    }

    @Test func pinnedTabsAreKeptInPinOrderApartFromTheOthers() throws {
        var (state, a, b, c) = home()
        let pinnedC = state.pin(tabID: c.id), pinnedA = state.pin(tabID: a.id), again = state.pin(tabID: a.id)
        #expect(pinnedC && pinnedA)
        #expect(!again, "pinned twice")
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [c.id, a.id])
        #expect(state.unpinnedTabs(inSpace: Space.defaultID).map(\.id) == [b.id])
        // Still tabs: the Space counts them, and the active one stays active.
        #expect(state.tabCount(inSpace: Space.defaultID) == 3)
        #expect(state.activeTabID == c.id)
        let pinned = try #require(state.tab(a.id))
        #expect(pinned.pinnedURL == a.url && pinned.pinName == "Inbox" && !pinned.isAwayFromPin)

        state.movePin(a.id, before: c.id)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [a.id, c.id])
        state.movePin(a.id, before: nil)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [c.id, a.id])
        // Not before a tab that isn't a pin.
        state.movePin(a.id, before: b.id)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [c.id, a.id])
    }

    @Test func aTabOpenedUnderAnotherIsListedRightBelowIt() {
        var (state, a, b, c) = home()
        #expect(state.listedTabs(inSpace: Space.defaultID).map(\.id) == [c.id, b.id, a.id])
        let child = state.openTab(url: url("https://b.example/next"), under: b.id, activate: false)
        let other = state.openTab(url: url("https://d.example"))
        #expect(state.listedTabs(inSpace: Space.defaultID).map(\.id) == [other.id, c.id, b.id, child.id, a.id])
        // Not under a pin, which isn't listed: first instead, and the pins keep their order.
        _ = state.pin(tabID: c.id)
        _ = state.pin(tabID: a.id)
        let afterPin = state.openTab(url: url("https://e.example"), under: c.id)
        #expect(state.listedTabs(inSpace: Space.defaultID).first?.id == afterPin.id)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [c.id, a.id])
        // Unpinned, a tab is listed first.
        state.unpin(tabID: c.id)
        #expect(state.listedTabs(inSpace: Space.defaultID).first?.id == c.id)
        // In Incognito too, under the page it came from.
        let page = state.openIncognitoTab(url: url("https://f.example"))
        let fromPage = state.openTab(url: url("https://f.example/next"), inSpace: Space.incognitoID, under: page.id)
        #expect(state.listedTabs(inSpace: Space.incognitoID).map(\.id) == [page.id, fromPage.id])
    }

    @Test func pinnedTabsNeverArchive() {
        var (state, a, b, _) = home()
        state.pin(tabID: a.id)
        let archived = state.runArchive(now: t0 + 30 * 24 * hour)
        #expect(archived.map(\.id) == [b.id])
        #expect(state.tab(a.id)?.isPinned == true)
    }

    @Test func incognitoAndBlankTabsCantBePinned() {
        var state = BrowserState()
        let blank = state.openTab(url: nil, now: t0)
        let incognito = state.openIncognitoTab(url: url("https://private.example"), now: t0)
        let pinnedBlank = state.pin(tabID: blank.id), pinnedIncognito = state.pin(tabID: incognito.id)
        #expect(!pinnedBlank)
        #expect(!pinnedIncognito)
        #expect(state.tabs.allSatisfy { !$0.isPinned })
    }

    @Test func leavingThePinnedPageIsAwayButNotItsFragmentOrTrailingSlash() {
        var (state, a, _, _) = home()
        state.pin(tabID: a.id)
        state.update(tabID: a.id, url: url("HTTPS://A.example/inbox/#starred"), title: nil)
        #expect(state.tab(a.id)?.isAwayFromPin == false)
        state.update(tabID: a.id, url: nil, title: "Starred")
        // Its page's title, kept up to date while it's on it.
        #expect(state.tab(a.id)?.pinName == "Starred")
        state.update(tabID: a.id, url: url("https://a.example/inbox?label=work"), title: "Work")
        #expect(state.tab(a.id)?.isAwayFromPin == true)
        #expect(state.tab(a.id)?.pinName == "Starred", "a page away from the pin renamed it")
        state.update(tabID: a.id, url: url("https://help.example"), title: "Help")
        #expect(state.tab(a.id)?.isAwayFromPin == true)
        #expect(state.tab(a.id)?.title == "Help")
    }

    @Test func renameNamesThePinUntilClearedAgain() {
        var (state, a, b, _) = home()
        state.pin(tabID: a.id)
        state.renamePin(a.id, to: "  Mail ")
        #expect(state.tab(a.id)?.pinName == "Mail")
        state.update(tabID: a.id, url: a.url, title: "Inbox (3)")
        #expect(state.tab(a.id)?.pinName == "Mail")
        state.renamePin(a.id, to: "   ")
        #expect(state.tab(a.id)?.pinName == "Inbox (3)")
        // Not a tab that isn't pinned.
        state.renamePin(b.id, to: "Nope")
        #expect(state.tab(b.id)?.customTitle == nil)
    }

    @Test func closingAPinnedTabTakesItBackToItsPageAsAFreshTab() throws {
        var (state, a, b, c) = home()
        state.pin(tabID: c.id)
        state.update(tabID: c.id, url: url("https://elsewhere.example"), title: "Elsewhere")
        state.renamePin(c.id, to: "Sea")
        state.close(tabID: c.id)

        let pins = state.pinnedTabs(inSpace: Space.defaultID)
        #expect(pins.count == 1)
        let fresh = try #require(pins.first)
        #expect(fresh.id != c.id, "the tab kept its ID, and with it its back/forward list")
        #expect(fresh.url == c.url && fresh.pinnedURL == c.url && !fresh.isAwayFromPin)
        #expect(fresh.title == "C" && fresh.pinName == "Sea")
        #expect(state.archived.isEmpty, "a pinned tab was archived")
        // The Space's most recent other tab is shown.
        #expect(state.activeTabID == b.id)
        #expect(state.tabs.count == 3)

        // An unpinned tab still archives.
        state.close(tabID: a.id)
        #expect(state.archived.map(\.id) == [a.id])
    }

    @Test func closingTheSpacesOnlyTabLeavesItPinnedWithNothingActive() {
        var state = BrowserState()
        let tab = state.openTab(url: url("https://a.example"), now: t0)
        state.pin(tabID: tab.id)
        state.close(tabID: tab.id)
        #expect(state.activeTabID == nil)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).count == 1)
    }

    @Test func resetKeepsAnActivePinActiveAndItsPlace() throws {
        var (state, a, b, c) = home()
        state.pin(tabID: a.id)
        state.pin(tabID: b.id)
        state.activate(tabID: a.id, now: t0 + 3 * hour)
        state.update(tabID: a.id, url: url("https://away.example"), title: "Away")
        let reset = state.resetPin(a.id)
        let fresh = try #require(reset)
        #expect(state.activeTabID == fresh.id)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [fresh.id, b.id])
        let notPinned = state.resetPin(c.id)
        #expect(notPinned == nil, "reset a tab that isn't pinned")
    }

    @Test func unpinMakesItAnOtherTabAndUndoPutsItBack() throws {
        var (state, a, b, c) = home()
        state.pin(tabID: a.id)
        state.pin(tabID: b.id)
        state.pin(tabID: c.id)
        state.renamePin(b.id, to: "Bee")
        state.update(tabID: b.id, url: url("https://b.example/away"), title: "Away")
        let unpinResult = state.unpin(tabID: b.id, now: t0 + 40 * 24 * hour)
        let undo = try #require(unpinResult)
        let unpinned = try #require(state.tab(b.id))
        #expect(!unpinned.isPinned && unpinned.pinnedURL == nil && unpinned.customTitle == nil)
        #expect(unpinned.url == url("https://b.example/away"), "unpinning moved the page")
        // Counted as viewed: not archived at once for the weeks it was pinned.
        let due = state.runArchive(now: t0 + 40 * 24 * hour)
        #expect(due.isEmpty)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [a.id, c.id])

        state.undoUnpin(undo)
        let back = try #require(state.tab(b.id))
        #expect(back.isPinned && back.pinnedURL == b.url && back.pinName == "Bee" && back.isAwayFromPin)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [a.id, b.id, c.id])
        let first = state.unpin(tabID: a.id), second = state.unpin(tabID: a.id)
        #expect(first != nil)
        #expect(second == nil, "unpinned twice")
    }

    @Test func aPinMovedToAnotherSpaceStaysPinnedAndGoesLast() {
        var (state, a, b, _) = home()
        let work = state.addSpace(name: "Work", now: t0)
        let w = state.openTab(url: url("https://w.example"), inSpace: work.id, activate: false, now: t0)
        state.pin(tabID: a.id)
        state.pin(tabID: w.id)
        // `a` is before `w` in `tabs`; moved, it goes after it.
        state.moveTab(a.id, toSpace: work.id, now: t0 + hour)
        #expect(state.pinnedTabs(inSpace: work.id).map(\.id) == [w.id, a.id])
        #expect(state.tab(a.id)?.isPinned == true)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).isEmpty)
        #expect(state.unpinnedTabs(inSpace: Space.defaultID).map(\.id).contains(b.id))
    }

    @Test func pinsSurviveSavingAndRepairsHoldOnLoad() throws {
        var (state, a, b, _) = home()
        state.pin(tabID: a.id)
        state.renamePin(a.id, to: "Mail")
        state.update(tabID: a.id, url: url("https://a.example/away"), title: "Away")
        let data = try CoreJSON.encoder().encode(state)
        let loaded = try CoreJSON.decoder().decode(BrowserState.self, from: data)
        let tab = try #require(loaded.tab(a.id))
        #expect(tab.isPinned && tab.pinnedURL == a.url && tab.pinName == "Mail" && tab.isAwayFromPin)
        #expect(loaded.tab(b.id)?.pinnedURL == nil)

        // A file from before pinned pages were kept: the page it's on is its pinned page. One that says a
        // tab with no page, or an unpinned one, has a pinned page is repaired.
        let json = """
            {"schemaVersion":4,"tabs":[
              {"id":"\(UUID())","url":"https://old.example","title":"Old","kind":"pinned"},
              {"id":"\(UUID())","title":"","kind":"pinned"},
              {"id":"\(UUID())","url":"https://x.example","kind":"today","pinnedURL":"https://x.example","customTitle":"X"}
            ]}
            """
        let old = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(old.tabs.map(\.isPinned) == [true, false, false])
        #expect(old.tabs[0].pinnedURL == url("https://old.example"))
        #expect(old.tabs[2].pinnedURL == nil && old.tabs[2].customTitle == nil)
    }

    @Test func aNavigationStartingDoesntNameThePinAfterThePageItLeft() {
        var (state, a, _, _) = home()
        state.pin(tabID: a.id)
        state.update(tabID: a.id, url: url("https://help.example"), title: "Help")
        // Back to the pinned page starts: the web view has its address and still Help's title.
        state.update(tabID: a.id, url: a.url, title: "Help")
        #expect(state.tab(a.id)?.pinName == "Inbox", "the pin took the title of the page it left")
        // Its own title arrives.
        state.update(tabID: a.id, url: a.url, title: "Inbox (2)")
        #expect(state.tab(a.id)?.pinName == "Inbox (2)")
    }

    @Test func onlyWebPagesCanBePinned() {
        var state = BrowserState()
        let blank = state.openTab(url: url("about:blank"), now: t0)
        let file = state.openTab(url: url("file:///tmp/a.html"), now: t0)
        let web = state.openTab(url: url("HTTPS://a.example"), now: t0)
        #expect(!state.canPin(blank.id) && !state.canPin(file.id))
        #expect(state.canPin(web.id))
    }

    @Test func aDraggedPinTakesThePlaceOfTheOneItsDroppedOn() {
        var state = BrowserState()
        let pins = (0..<4).map { state.openTab(url: url("https://p\($0).example"), now: t0 + Double($0)) }
        for pin in pins { state.pin(tabID: pin.id) }
        func order() -> [UUID] { state.pinnedTabs(inSpace: Space.defaultID).map(\.id) }
        // Left to right: after the target.
        state.movePin(pins[0].id, onto: pins[2].id)
        #expect(order() == [pins[1].id, pins[2].id, pins[0].id, pins[3].id])
        // To the last place.
        state.movePin(pins[1].id, onto: pins[3].id)
        #expect(order() == [pins[2].id, pins[0].id, pins[3].id, pins[1].id])
        // Right to left: before the target.
        state.movePin(pins[1].id, onto: pins[2].id)
        #expect(order() == [pins[1].id, pins[2].id, pins[0].id, pins[3].id])
        let ontoItself = state.movePin(pins[1].id, onto: pins[1].id)
        #expect(!ontoItself)
    }

    @Test func undoingAMoveToSpacePutsThePinBackInItsPlace() {
        var (state, a, b, c) = home()
        for tab in [a, b, c] { state.pin(tabID: tab.id) }
        let work = state.addSpace(name: "Work", now: t0)
        let before = state.pinAfter(a.id)
        #expect(before == b.id)
        state.moveTabAndFollow(a.id, toSpace: work.id, now: t0 + hour)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [b.id, c.id])
        state.moveTabBack(a.id, toSpace: Space.defaultID, wasActive: false, returningTo: Space.defaultID,
                          pinnedBefore: before, now: t0 + 2 * hour)
        #expect(state.pinnedTabs(inSpace: Space.defaultID).map(\.id) == [a.id, b.id, c.id])
    }

    @Test func searchFindsAPinByItsNewName() {
        var (state, a, _, _) = home()
        state.pin(tabID: a.id)
        state.renamePin(a.id, to: "Work mail")
        let search = TabSearch(tabs: state.tabs, query: "work mail")
        #expect(search.tabs.map(\.id) == [a.id])
    }
}
