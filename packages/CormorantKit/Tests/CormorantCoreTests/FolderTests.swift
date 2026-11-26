import Foundation
import Testing
@testable import CormorantCore

@Suite struct FolderTests {
    /// Home with four tabs opened an hour apart; `d` is active. Listed newest first: d, c, b, a.
    private func home() -> (BrowserState, a: Tab, b: Tab, c: Tab, d: Tab) {
        var state = BrowserState()
        let a = state.openTab(url: url("https://a.example"), title: "A", now: t0)
        let b = state.openTab(url: url("https://b.example"), title: "B", now: t0 + hour)
        let c = state.openTab(url: url("https://c.example"), title: "C", now: t0 + 2 * hour)
        let d = state.openTab(url: url("https://d.example"), title: "D", now: t0 + 3 * hour)
        return (state, a, b, c, d)
    }

    private func shape(_ items: [SidebarItem]) -> [String] {
        items.map { item in
            switch item {
            case .tab(let tab): tab.title
            case .folder(let folder, let tabs): "\(folder.name)[\(tabs.map(\.title).joined(separator: ","))]"
            }
        }
    }

    @Test func aFolderShowsWhereItsFirstTabIsAndGoesWhenEmptied() throws {
        var (state, a, b, c, _) = home()
        let made = state.newFolder(with: c.id, name: "  Trip ", now: t0)
        let folder = try #require(made)
        #expect(folder.name == "Trip")
        #expect(shape(state.listedItems(inSpace: Space.defaultID)) == ["D", "Trip[C]", "B", "A"])

        // Joining puts a tab last in the folder; leaving puts it just after the folder.
        let r1 = state.addToFolder(a.id, folder.id)
        #expect(r1)
        let r2 = state.addToFolder(b.id, folder.id)
        #expect(r2)
        #expect(shape(state.listedItems(inSpace: Space.defaultID)) == ["D", "Trip[C,A,B]"])
        let r3 = state.addToFolder(b.id, folder.id)
        #expect(!r3, "already in it")
        state.removeFromFolder(a.id)
        #expect(shape(state.listedItems(inSpace: Space.defaultID)) == ["D", "Trip[C,B]", "A"])

        state.removeFromFolder(c.id)
        state.removeFromFolder(b.id)
        #expect(state.folders.isEmpty, "an empty folder goes")
        #expect(state.listedItems(inSpace: Space.defaultID).allSatisfy { if case .tab = $0 { true } else { false } })
    }

    @Test func pinsAreTilesOrRowsOfThePinnedListWhichHoldsFolders() throws {
        var (state, a, b, c, d) = home()
        state.pin(tabID: a.id)
        state.pin(tabID: b.id, place: .list)
        state.pin(tabID: c.id, place: .list)
        #expect(state.tilePins(inSpace: Space.defaultID).map(\.id) == [a.id])
        #expect(shape(state.pinnedList(inSpace: Space.defaultID)) == ["B", "C"])

        // A tile put in a folder becomes a row of the list; a tab that isn't pinned joining a pinned
        // folder is pinned, on its page.
        let r4 = state.newFolder(with: a.id, name: "Mail")
        let folder = try #require(r4)
        #expect(state.tab(a.id)?.pinPlace == .list)
        #expect(state.tilePins(inSpace: Space.defaultID).isEmpty)
        let r5 = state.addToFolder(d.id, folder.id)
        #expect(r5)
        let joined = try #require(state.tab(d.id))
        #expect(joined.isPinned && joined.pinPlace == .list && joined.pinnedURL == d.url)
        #expect(shape(state.pinnedList(inSpace: Space.defaultID)) == ["Mail[A,D]", "B", "C"])
        #expect(state.isPinnedFolder(folder.id))

        // The iPhone's row: the tiles, then the list.
        state.movePin(b.id, to: .tile)
        #expect(shape(state.pinRow(inSpace: Space.defaultID)) == ["B", "Mail[A,D]", "C"])
        #expect(state.tilePins(inSpace: Space.defaultID).map(\.id) == [b.id])

        // A list pin moved to the tiles leaves its folder.
        state.movePin(a.id, to: .tile)
        #expect(state.tab(a.id)?.folderID == nil)
        #expect(shape(state.pinnedList(inSpace: Space.defaultID)) == ["Mail[D]", "C"])
    }

    @Test func aFolderMovesBetweenThePinnedListAndTheOtherTabsWhole() throws {
        var (state, a, b, c, _) = home()
        let r6 = state.newFolder(with: c.id, name: "Docs")
        let folder = try #require(r6)
        state.addToFolder(b.id, folder.id)
        state.addToFolder(a.id, folder.id)
        state.moveFolder(folder.id, toPinned: true)
        #expect(shape(state.pinnedList(inSpace: Space.defaultID)) == ["Docs[C,B,A]"])
        #expect(state.tabs(inFolder: folder.id).allSatisfy { $0.isPinned && $0.pinPlace == .list })
        state.moveFolder(folder.id, toPinned: false)
        #expect(shape(state.listedItems(inSpace: Space.defaultID)) == ["Docs[C,B,A]", "D"])
        #expect(state.pinnedList(inSpace: Space.defaultID).isEmpty)
    }

    @Test func aFolderAmongTheTabsArchivesWholeOnceAllItsTabsAreIdle() throws {
        var (state, a, b, _, _) = home()
        let r7 = state.newFolder(with: a.id, name: "Old")
        let folder = try #require(r7)
        state.addToFolder(b.id, folder.id)
        // A day after `a` was opened, `a` alone is due, but it's in a folder with `b`, which isn't.
        #expect(state.runArchive(now: t0 + 24 * hour + 30 * 60).isEmpty)
        #expect(state.tabsDue(inSpace: Space.defaultID, now: t0 + 24 * hour + 30 * 60).isEmpty)

        let due = state.tabsDue(inSpace: Space.defaultID, now: t0 + 25 * hour).map(\.id)
        #expect(Set(due) == [a.id, b.id])
        let archived = state.runArchive(now: t0 + 25 * hour)
        #expect(Set(archived.map(\.id)) == [a.id, b.id])
        #expect(archived.allSatisfy { $0.folder?.id == folder.id && $0.folder?.name == "Old" })
        #expect(state.folders.isEmpty)

        // Restoring one brings the folder back with both, the one chosen active.
        let r8 = state.restore(archivedID: b.id, now: t0 + 26 * hour)
        let restored = try #require(r8)
        #expect(state.activeTabID == restored.id)
        #expect(state.archived.isEmpty)
        #expect(shape(state.listedItems(inSpace: Space.defaultID)) == ["Old[A,B]", "D", "C"])
    }

    @Test func theActiveTabKeepsItsFolderFromArchiving() throws {
        var (state, a, b, _, _) = home()
        let r9 = state.newFolder(with: a.id)
        let folder = try #require(r9)
        state.addToFolder(b.id, folder.id)
        state.activate(tabID: b.id, now: t0 + hour)
        #expect(state.runArchive(now: t0 + 30 * 24 * hour).allSatisfy { $0.folder == nil })
        #expect(state.folder(folder.id) != nil)
    }

    @Test func closingAFolderArchivesItsPinsTooAndUndoBringsItBackUnpinned() throws {
        var (state, a, b, _, _) = home()
        state.pin(tabID: a.id, place: .list)
        let r10 = state.newFolder(with: a.id, name: "Pinned")
        let folder = try #require(r10)
        state.addToFolder(b.id, folder.id)
        state.closeFolder(folder.id, now: t0 + 5 * hour)
        #expect(state.tab(a.id) == nil && state.tab(b.id) == nil)
        #expect(state.archived.filter { $0.folder?.id == folder.id }.count == 2)
        state.restore(archivedID: a.id, now: t0 + 6 * hour)
        let back = try #require(state.folders.first)
        #expect(back.name == "Pinned")
        #expect(state.tabs(inFolder: back.id).map(\.title) == ["A", "B"])
        #expect(!state.isPinnedFolder(back.id))
    }

    @Test func unpinningTheLastTabOfAPinnedFolderUndoesWithTheFolder() throws {
        var (state, a, _, _, _) = home()
        state.pin(tabID: a.id, place: .list)
        let r11 = state.newFolder(with: a.id, name: "Solo")
        let folder = try #require(r11)
        let r12 = state.unpin(tabID: a.id)
        let undo = try #require(r12)
        #expect(state.folders.isEmpty)
        state.undoUnpin(undo)
        #expect(shape(state.pinnedList(inSpace: Space.defaultID)) == ["Solo[A]"])
        #expect(state.folder(folder.id) != nil)
    }

    @Test func aTabMovedToAnotherSpaceLeavesItsFolder() throws {
        var (state, a, b, _, _) = home()
        let work = state.addSpace(name: "Work", now: t0)
        let r13 = state.newFolder(with: a.id)
        let folder = try #require(r13)
        state.addToFolder(b.id, folder.id)
        #expect(!state.canAdd(a.id, toFolder: UUID()))
        state.moveTab(a.id, toSpace: work.id, now: t0 + hour)
        #expect(state.tab(a.id)?.folderID == nil)
        #expect(state.tabs(inFolder: folder.id).map(\.id) == [b.id])
        state.moveTab(b.id, toSpace: work.id, now: t0 + hour)
        #expect(state.folders.isEmpty)
    }

    @Test func foldersSurviveSavingAndRepairsHoldOnLoad() throws {
        var (state, a, b, _, _) = home()
        let r14 = state.newFolder(with: a.id, name: "Kept")
        let folder = try #require(r14)
        state.addToFolder(b.id, folder.id)
        state.setFolderIcon(folder.id, "cloud.fill")
        state.setFolderOpen(folder.id, false)
        let data = try CoreJSON.encoder().encode(state)
        let loaded = try CoreJSON.decoder().decode(BrowserState.self, from: data)
        #expect(loaded.folders == state.folders)
        #expect(shape(loaded.listedItems(inSpace: Space.defaultID)) == shape(state.listedItems(inSpace: Space.defaultID)))

        // A tab whose folder is unknown, one of another Space, a folder of mixed kinds (the first tab's
        // kind wins), and a folder with no tab.
        let f1 = UUID(), f2 = UUID(), f3 = UUID(), other = UUID()
        let json = """
            {"schemaVersion":6,
             "spaces":[{"id":"\(Space.defaultID)","name":"Home"},{"id":"\(other)","name":"Work"}],
             "folders":[{"id":"\(f1)","spaceID":"\(Space.defaultID)","name":"Mixed"},
                        {"id":"\(f2)","spaceID":"\(other)","name":"Elsewhere"},
                        {"id":"\(f3)","spaceID":"\(Space.defaultID)","name":"Empty"}],
             "tabs":[
              {"id":"\(UUID())","url":"https://p.example","kind":"pinned","pinPlace":"tile","folderID":"\(f1)"},
              {"id":"\(UUID())","url":"https://t.example","kind":"today","folderID":"\(f1)"},
              {"id":"\(UUID())","url":"https://e.example","kind":"today","folderID":"\(f2)"},
              {"id":"\(UUID())","url":"https://u.example","kind":"today","folderID":"\(UUID())"}
            ]}
            """
        let old = try CoreJSON.decoder().decode(BrowserState.self, from: Data(json.utf8))
        #expect(old.folders.map(\.id) == [f1])
        #expect(old.tabs.map { $0.folderID } == [f1, nil, nil, nil])
        #expect(old.tabs[0].pinPlace == .list)
    }

    @Test func anyTabCanBeRenamed() {
        var (state, a, _, _, _) = home()
        state.rename(a.id, to: " Alpha ")
        #expect(state.tab(a.id)?.displayTitle == "Alpha")
        state.update(tabID: a.id, url: url("https://a.example/next"), title: "Next")
        #expect(state.tab(a.id)?.displayTitle == "Alpha")
        state.rename(a.id, to: "")
        #expect(state.tab(a.id)?.displayTitle == "Next")
    }
}

@Suite struct FolderReviewTests {
    private func home() -> (BrowserState, a: Tab, b: Tab, c: Tab) {
        var state = BrowserState()
        let a = state.openTab(url: url("https://a.example"), title: "A", now: t0)
        let b = state.openTab(url: url("https://b.example"), title: "B", now: t0 + hour)
        let c = state.openTab(url: url("https://c.example"), title: "C", now: t0 + 2 * hour)
        return (state, a, b, c)
    }

    @Test func pinningAOneTabFolderKeepsTheFolder() throws {
        var (state, a, _, _) = home()
        let made = state.newFolder(with: a.id, name: "Solo")
        let folder = try #require(made)
        state.moveFolder(folder.id, toPinned: true)
        #expect(state.folder(folder.id) != nil)
        #expect(state.tab(a.id)?.folderID == folder.id && state.tab(a.id)?.pinPlace == .list)
        state.moveFolder(folder.id, toPinned: false)
        #expect(state.folder(folder.id) != nil && state.tab(a.id)?.isPinned == false)
        #expect(state.tabs.allSatisfy { $0.folderID == nil || state.folder($0.folderID!) != nil })
    }

    @Test func undoUnpinLeavesAFolderJoinedSince() throws {
        var (state, a, b, c) = home()
        state.pin(tabID: a.id)
        let made = state.newFolder(with: b.id, name: "G")
        let folder = try #require(made)
        state.addToFolder(c.id, folder.id)
        let unpinned = state.unpin(tabID: a.id)
        let undo = try #require(unpinned)
        state.addToFolder(a.id, folder.id)
        state.undoUnpin(undo)
        #expect(state.tab(a.id)?.isPinned == true && state.tab(a.id)?.folderID == nil)
        #expect(Set(state.tabs(inFolder: folder.id).map(\.id)) == [b.id, c.id])
        #expect(!state.isPinnedFolder(folder.id))
    }

    @Test func aRenamedTabIsStillFoundByItsPage() {
        var (state, a, b, _) = home()
        state.rename(a.id, to: "Mail")
        #expect(state.tab(a.id)?.searchTitle == "Mail A")
        state.pin(tabID: b.id)
        state.renamePin(b.id, to: "Bee")
        #expect(state.tab(b.id)?.searchTitle == "Bee B")
    }

    @Test func undoingCloseFolderPutsPinsBackAsPins() throws {
        var (state, a, b, _) = home()
        state.pin(tabID: a.id, place: .list)
        state.rename(a.id, to: "Alpha")
        let made = state.newFolder(with: a.id, name: "P")
        let folder = try #require(made)
        state.addToFolder(b.id, folder.id)
        let before = state.tabs
        let closed = state.closeFolder(folder.id)
        let token = try #require(closed)
        state.undoCloseFolder(token)
        #expect(state.tabs == before)
        #expect(state.archived.isEmpty)
        #expect(state.tab(a.id)?.pinName == "Alpha")
    }

    @Test func undoingAMoveToAnotherSpacePutsTheTabBackInItsFolder() throws {
        var (state, a, _, _) = home()
        let work = state.addSpace(name: "Work", now: t0)
        let made = state.newFolder(with: a.id, name: "Solo")
        let folder = try #require(made)
        state.moveTab(a.id, toSpace: work.id, now: t0 + hour)
        #expect(state.folders.isEmpty)
        state.moveTabBack(a.id, toSpace: Space.defaultID, wasActive: false)
        state.rejoinFolder(a.id, folder)
        #expect(state.tab(a.id)?.folderID == folder.id && state.folder(folder.id) != nil)
    }

    @Test func closingAFoldersLastTabDropsTheFolder() throws {
        var (state, a, _, _) = home()
        let made = state.newFolder(with: a.id)
        _ = try #require(made)
        state.archive(tabID: a.id)
        #expect(state.folders.isEmpty)
    }

    @Test func aPinDroppedOnThePinnedListJoinsItWhereItWasDropped() {
        var (state, a, b, c) = home()
        let d = state.openTab(url: url("https://d.example"), title: "D", now: t0 + 3 * hour)
        state.pin(tabID: a.id)
        state.pin(tabID: b.id)
        state.pin(tabID: c.id, place: .list)
        state.pin(tabID: d.id, place: .list)
        // Row: A B | C D. B dropped on C comes from C's left: after it.
        let joined = state.movePin(b.id, onto: c.id)
        #expect(joined)
        #expect(state.tilePins(inSpace: Space.defaultID).map(\.id) == [a.id])
        #expect(state.pinnedList(inSpace: Space.defaultID).map(\.id) == [c.id, b.id, d.id])
        // D dropped on A comes from A's right: before it.
        let back = state.movePin(d.id, onto: a.id)
        #expect(back)
        #expect(state.tilePins(inSpace: Space.defaultID).map(\.id) == [d.id, a.id])
        let moved = state.movePin(d.id, onto: a.id)
        #expect(moved)
        #expect(state.tilePins(inSpace: Space.defaultID).map(\.id) == [a.id, d.id])
    }
}
