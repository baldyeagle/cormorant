import Foundation
import Testing
@testable import CormorantCore

/// Links from other apps: the Space a share-extension request names, a Focus filter's Space, the
/// summary file the extension reads, and where the Focus filter's Space is kept.
@Suite struct SpacesLinksTests {
    // MARK: OpenRequest

    @Test func requestRoundTripsWithAndWithoutSpace() throws {
        let space = UUID()
        let requests = [OpenRequest(url: url("https://a.com"), receivedAt: t0, spaceID: space),
                        OpenRequest(url: url("https://b.com"), receivedAt: t0 + hour)]
        let data = try CoreJSON.encoder().encode(requests)
        #expect(try CoreJSON.decoder().decode([OpenRequest].self, from: data) == requests)
        // No key at all for a request without a Space, as before Spaces.
        #expect(!String(decoding: data, as: UTF8.self).contains("null"))
    }

    /// An inbox written before requests could name a Space (reference-date numbers, or ISO 8601 from
    /// earlier still) drains as requests with no Space.
    @Test func oldInboxDrainsWithNoSpace() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "inbox.json")
        let first = UUID(), second = UUID()
        let json = """
            [{"id":"\(first)","receivedAt":\(t0.timeIntervalSinceReferenceDate),"url":"https://a.com"},
             {"id":"\(second)","receivedAt":"2026-09-21T10:00:00Z","url":"https://b.com/x?y=1"}]
            """
        try Data(json.utf8).write(to: fileURL)
        let drained = try SharedInbox(fileURL: fileURL).drain()
        #expect(Set(drained.map(\.id)) == [first, second])
        #expect(drained.allSatisfy { $0.spaceID == nil })
        #expect(drained.map(\.url).contains(url("https://b.com/x?y=1")))
    }

    /// A Space ID this build can't read costs the Space, not the link.
    @Test func unreadableSpaceDecodesAsNone() throws {
        let id = UUID()
        let json = """
            [{"id":"\(id)","receivedAt":0,"url":"https://a.com","spaceID":"not-a-uuid"},
             {"id":"\(UUID())","receivedAt":1,"url":"https://b.com","spaceID":null}]
            """
        let requests = try CoreJSON.decoder().decode([OpenRequest].self, from: Data(json.utf8))
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.spaceID == nil })
        #expect(requests[0].id == id)
    }

    @Test func requestWithSpaceSurvivesTheInbox() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = SharedInbox(fileURL: dir.appending(path: "inbox.json"))
        let request = OpenRequest(url: url("https://a.com"), receivedAt: t0, spaceID: UUID())
        try inbox.append(request)
        #expect(try inbox.drain() == [request])
    }

    // MARK: Choosing the Space

    @Test func requestedSpaceWinsOverFocusAndLastUsed() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work"), trip = state.addSpace(name: "Trip")
        let route = state.destinationForLink(requestedSpace: trip.id, focusSpace: work.id)
        #expect(route.spaceID == trip.id && route.reason == .requested)
    }

    @Test func focusSpaceWinsOverLastUsed() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let route = state.destinationForLink(requestedSpace: nil, focusSpace: work.id)
        #expect(route.spaceID == work.id && route.reason == .focus)
        // Even when it's the Space last used: the toast still says the Focus sent it.
        state.switchToSpace(work.id, now: t0)
        #expect(state.destinationForLink(requestedSpace: nil, focusSpace: work.id).reason == .focus)
    }

    @Test func noRequestOrFocusOpensInTheSpaceLastUsed() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        state.switchToSpace(work.id, now: t0)
        let route = state.destinationForLink(requestedSpace: nil, focusSpace: nil)
        #expect(route.spaceID == work.id && route.reason == .lastUsed)
    }

    /// An archived or deleted requested Space falls to the Focus filter's, and an archived or deleted
    /// Focus Space to the Space last used.
    @Test func archivedAndDeletedSpacesFallThrough() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work"), trip = state.addSpace(name: "Trip")
        let projects = state.addSpace(name: "Projects")
        state.switchToSpace(projects.id, now: t0)
        state.archiveSpace(trip.id, now: t0)

        var route = state.destinationForLink(requestedSpace: trip.id, focusSpace: work.id)
        #expect(route.spaceID == work.id && route.reason == .focus)
        route = state.destinationForLink(requestedSpace: UUID(), focusSpace: work.id)
        #expect(route.spaceID == work.id && route.reason == .focus)

        route = state.destinationForLink(requestedSpace: nil, focusSpace: trip.id)
        #expect(route.spaceID == projects.id && route.reason == .lastUsed)
        state.deleteSpace(work.id, now: t0)
        route = state.destinationForLink(requestedSpace: work.id, focusSpace: work.id)
        #expect(route.spaceID == projects.id && route.reason == .lastUsed)
    }

    // MARK: Spaces summary

    @Test func summaryListsSwitchableSpacesInOrder() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work", icon: .briefcase, color: .indigo)
        let trip = state.addSpace(name: "Trip", icon: .airplane, color: .green)
        let projects = state.addSpace(name: "Projects", icon: .hammer, color: .orange)
        state.archiveSpace(trip.id, now: t0)
        state.moveSpace(projects.id, before: work.id)
        state.switchToSpace(work.id, now: t0)

        let summary = SpacesSummary(state)
        #expect(summary.spaces.map(\.name) == ["Home", "Projects", "Work"])
        #expect(summary.spaces[2] == SpacesSummary.Entry(id: work.id, name: "Work", icon: .briefcase, color: .indigo))
        #expect(summary.activeSpaceID == work.id)
        #expect(summary.hasSpacesToChoose)
        #expect(!SpacesSummary(BrowserState()).hasSpacesToChoose)
    }

    @Test func summaryDefaultSpaceFollowsFocusThenLastUsed() {
        var state = BrowserState()
        let work = state.addSpace(name: "Work")
        let projects = state.addSpace(name: "Projects")
        state.switchToSpace(projects.id, now: t0)
        let summary = SpacesSummary(state)
        #expect(summary.defaultSpace(focusSpace: work.id)?.id == work.id)
        #expect(summary.defaultSpace(focusSpace: nil)?.id == projects.id)
        #expect(summary.defaultSpace(focusSpace: UUID())?.id == projects.id)
        // A file that names no active Space (or a gone one): the first.
        #expect(SpacesSummary(spaces: summary.spaces, activeSpaceID: nil).defaultSpace(focusSpace: nil)?.id == Space.defaultID)
        #expect(SpacesSummary(spaces: [], activeSpaceID: nil).defaultSpace(focusSpace: nil) == nil)
    }

    @Test func summaryFileRoundTrips() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var state = BrowserState()
        state.addSpace(name: "Work", icon: .briefcase, color: .indigo)
        let file = SpacesSummaryFile(fileURL: dir.appending(path: "group/spaces-summary.json"))
        #expect(file.read() == nil)
        try file.write(SpacesSummary(state))
        #expect(file.read() == SpacesSummary(state))
        let json = try String(contentsOf: file.fileURL, encoding: .utf8)
        #expect(json.contains("\"version\":1"))
    }

    /// Unknown fields, icons and colors are ignored or defaulted; an entry without an ID is left out;
    /// a file that isn't a summary, or is too big, reads as none, and is left where it is.
    @Test func summaryDecodesTolerantly() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = SpacesSummaryFile(fileURL: dir.appending(path: "spaces-summary.json"))
        let home = Space.defaultID, work = UUID()
        let json = """
            {"version":7,"future":{"x":1},"activeSpaceID":"\(work)","spaces":[
              {"id":"\(home)","name":"Home","icon":"house","color":"teal"},
              {"name":"No ID"},
              {"id":"\(work)","name":"Work","icon":"rocket","color":"ultraviolet","extra":true}]}
            """
        try Data(json.utf8).write(to: file.fileURL)
        let summary = try #require(file.read())
        #expect(summary.spaces.map(\.id) == [home, work])
        #expect(summary.spaces[1].icon == .house && summary.spaces[1].color == .teal)
        #expect(summary.activeSpaceID == work)

        try Data("garbage".utf8).write(to: file.fileURL)
        #expect(file.read() == nil)
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path(percentEncoded: false)))

        try Data(repeating: 0x20, count: SpacesSummaryFile.maximumSize + 1).write(to: file.fileURL)
        #expect(file.read() == nil)
    }

    // MARK: Focus filter's Space

    @Test func focusSpaceIsKeptInDefaults() throws {
        let suite = "CormorantCoreTests.focus.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FocusFilterSpace.read(from: defaults) == nil)
        let work = UUID()
        FocusFilterSpace.write(work, to: defaults)
        #expect(FocusFilterSpace.read(from: defaults) == work)
        // Another instance on the same suite (as after a relaunch) sees it.
        #expect(FocusFilterSpace.read(from: try #require(UserDefaults(suiteName: suite))) == work)
        FocusFilterSpace.write(nil, to: defaults)
        #expect(FocusFilterSpace.read(from: defaults) == nil)
        defaults.set("garbage", forKey: FocusFilterSpace.key)
        #expect(FocusFilterSpace.read(from: defaults) == nil)
    }
}
