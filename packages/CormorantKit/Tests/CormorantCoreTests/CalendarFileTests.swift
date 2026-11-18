import Foundation
import Testing
@testable import CormorantCore

@Suite struct CalendarFileTests {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ string: String, in zone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = string.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    @Test func readsATimedEventInUTC() {
        let ics = """
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            BEGIN:VEVENT\r
            UID:1@example.com\r
            SUMMARY:Launch review\r
            DTSTART:20261120T150000Z\r
            DTEND:20261120T160000Z\r
            LOCATION:Room 4\\, second floor\r
            DESCRIPTION:Agenda:\\n1. Bugs\\n2. Ship\r
            URL:https://example.com/meet\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        let events = CalendarFile.events(in: ics, defaultTimeZone: newYork)
        #expect(events == [CalendarEvent(
            title: "Launch review", start: date("2026-11-20 15:00", in: utc), end: date("2026-11-20 16:00", in: utc),
            isAllDay: false, location: "Room 4, second floor", notes: "Agenda:\n1. Bugs\n2. Ship",
            url: URL(string: "https://example.com/meet"))])
    }

    @Test func unfoldsLongLinesAndReadsTZID() {
        let ics = """
            BEGIN:VEVENT
            SUMMARY:A very long title that the server
             folded onto two lines
            DTSTART;TZID=America/Los_Angeles:20261201T090000
            DURATION:PT1H30M
            END:VEVENT
            """
        let event = CalendarFile.events(in: ics, defaultTimeZone: newYork).first
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(event?.title == "A very long title that the serverfolded onto two lines")
        #expect(event?.start == date("2026-12-01 09:00", in: la))
        #expect(event?.end == date("2026-12-01 10:30", in: la))
    }

    @Test func readsOutlooksWindowsTimeZoneNames() {
        let ics = """
            BEGIN:VEVENT
            SUMMARY:Sync
            DTSTART;TZID="Eastern Standard Time":20261201T090000
            DTEND;TZID="Eastern Standard Time":20261201T093000
            END:VEVENT
            """
        let event = CalendarFile.events(in: ics, defaultTimeZone: utc).first
        #expect(event?.start == date("2026-12-01 09:00", in: newYork))
    }

    @Test func floatingTimesAreLocal() {
        let ics = "BEGIN:VEVENT\nSUMMARY:Lunch\nDTSTART:20261201T120000\nEND:VEVENT"
        let event = CalendarFile.events(in: ics, defaultTimeZone: newYork).first
        #expect(event?.start == date("2026-12-01 12:00", in: newYork))
        #expect(event?.end == event?.start)
    }

    @Test func allDayEventsKeepTheirDays() {
        let ics = """
            BEGIN:VEVENT
            SUMMARY:Conference
            DTSTART;VALUE=DATE:20261203
            DTEND;VALUE=DATE:20261205
            END:VEVENT
            BEGIN:VEVENT
            SUMMARY:Holiday
            DTSTART:20261225
            END:VEVENT
            """
        let events = CalendarFile.events(in: ics, defaultTimeZone: newYork)
        #expect(events.count == 2)
        #expect(events[0].isAllDay)
        #expect(events[0].start == date("2026-12-03", in: newYork))
        #expect(events[0].end == date("2026-12-05", in: newYork))
        #expect(events[1].isAllDay)
        #expect(events[1].end == date("2026-12-26", in: newYork))
    }

    @Test func skipsAlarmsAndEventsWithoutAStart() {
        let ics = """
            BEGIN:VEVENT
            SUMMARY:Dentist
            DTSTART:20261201T080000Z
            BEGIN:VALARM
            DESCRIPTION:Not the event's notes
            TRIGGER:-PT15M
            END:VALARM
            RRULE:FREQ=WEEKLY;COUNT=3
            END:VEVENT
            BEGIN:VEVENT
            SUMMARY:No start
            END:VEVENT
            """
        let events = CalendarFile.events(in: ics)
        #expect(events.count == 1)
        #expect(events[0].notes == nil)
        #expect(events[0].recurrence == "FREQ=WEEKLY;COUNT=3")
    }

    @Test func untitledEventsGetAName() {
        let event = CalendarFile.events(in: "BEGIN:VEVENT\nDTSTART:20261201T080000Z\nEND:VEVENT").first
        #expect(event?.title == "Event")
    }

    @Test func durations() {
        #expect(CalendarFile.seconds(inDuration: "P1W") == 604_800)
        #expect(CalendarFile.seconds(inDuration: "P1DT2H") == 93_600)
        #expect(CalendarFile.seconds(inDuration: "PT45M") == 2_700)
        #expect(CalendarFile.seconds(inDuration: "-PT15M") == nil)
        #expect(CalendarFile.seconds(inDuration: "PT1H30") == nil)
    }

    /// Folded in the middle of "é" (C3 A9): unfolded as bytes, so it's still UTF-8.
    @Test func foldsInsideACharacterAreJoinedBeforeDecoding() throws {
        var data = Data("BEGIN:VEVENT\r\nSUMMARY:Caf".utf8)
        data += [0xC3, 0x0D, 0x0A, 0x20, 0xA9]
        data += Data(" au lait\r\nDTSTART:20261201T080000Z\r\nEND:VEVENT\r\n".utf8)
        let text = try #require(CalendarFile.text(from: data))
        #expect(CalendarFile.events(in: text).first?.title == "Café au lait")
    }

    @Test func notUTF8IsReadAsLatin1() {
        #expect(CalendarFile.text(from: Data([0x43, 0x61, 0x66, 0xE9])) == "Café")
    }

    @Test func notACalendarHasNoEvents() {
        #expect(CalendarFile.events(in: "<html>nope</html>").isEmpty)
    }
}
