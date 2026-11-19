import Foundation

/// One event from an iCalendar (.ics) file, as much of it as the system's New Event editor takes.
public struct CalendarEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    /// Exclusive, as in the file: for an all-day event, the day after its last.
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var url: URL?
    /// The file's `RRULE`, unparsed: the editor gets the first occurrence, and the browser says so.
    public var recurrence: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool, location: String? = nil,
                notes: String? = nil, url: URL? = nil, recurrence: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.recurrence = recurrence
    }
}

/// Reads the `VEVENT`s out of an iCalendar file (RFC 5545): folded lines, escaped text, `DTSTART`
/// / `DTEND` / `DURATION` in UTC, with a `TZID`, floating (local) or as dates (all day). Enough for
/// the event links sites offer ("Add to calendar"); not a full parser: no `VTIMEZONE` definitions
/// (a `TZID` that isn't an IANA or common Windows name is read as local time), no alarms, attendees
/// or recurrence expansion.
public enum CalendarFile {
    public static func events(in text: String, defaultTimeZone: TimeZone = .current) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var current: [Property]?
        var depth = 0  // components nested inside the VEVENT (VALARM)
        for line in unfolded(text) {
            guard let property = Property(line) else { continue }
            switch (property.name, property.value.uppercased()) {
            case ("BEGIN", "VEVENT") where current == nil:
                current = []
            case ("BEGIN", _) where current != nil:
                depth += 1
            case ("END", "VEVENT") where depth == 0:
                if let properties = current, let event = event(from: properties, timeZone: defaultTimeZone) {
                    events.append(event)
                }
                current = nil
            case ("END", _) where current != nil:
                depth = max(0, depth - 1)
            default:
                if depth == 0 { current?.append(property) }
            }
        }
        return events
    }

    /// A calendar file's text: unfolded as bytes first, since a server may fold a line in the middle
    /// of a character's UTF-8 bytes (RFC 5545 §3.1); then UTF-8, or Latin-1 if it isn't.
    public static func text(from data: Data) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            // CRLF or LF, then a space or tab: the line goes on.
            let next = data.index(after: index)
            if byte == 0x0D, next < data.endIndex, data[next] == 0x0A {
                let after = data.index(after: next)
                if after < data.endIndex, data[after] == 0x20 || data[after] == 0x09 {
                    index = data.index(after: after)
                    continue
                }
            } else if byte == 0x0A, next < data.endIndex, data[next] == 0x20 || data[next] == 0x09 {
                index = data.index(after: next)
                continue
            }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
    }

    // MARK: Lines

    /// CRLF or LF line ends; a line starting with a space or tab continues the one before.
    static func unfolded(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    struct Property {
        let name: String
        let parameters: [String: String]
        let value: String

        /// `NAME;PARAM=x;PARAM="y:z":value`: the value starts at the first colon outside quotes.
        init?(_ line: String) {
            var inQuotes = false
            var split: String.Index?
            for index in line.indices {
                let character = line[index]
                if character == "\"" { inQuotes.toggle() }
                if character == ":" && !inQuotes { split = index; break }
            }
            guard let split else { return nil }
            let head = line[..<split].split(separator: ";", omittingEmptySubsequences: false)
            guard let name = head.first, !name.isEmpty else { return nil }
            self.name = name.uppercased()
            var parameters: [String: String] = [:]
            for parameter in head.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            self.parameters = parameters
            value = String(line[line.index(after: split)...])
        }
    }

    // MARK: Events

    private static func event(from properties: [Property], timeZone: TimeZone) -> CalendarEvent? {
        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        guard let startProperty = first("DTSTART"),
              let (start, allDay) = date(startProperty, defaultTimeZone: timeZone) else { return nil }
        var end: Date
        if let endProperty = first("DTEND"), let (date, _) = date(endProperty, defaultTimeZone: timeZone), date >= start {
            end = date
        } else if let duration = first("DURATION").flatMap({ seconds(inDuration: $0.value) }) {
            end = start.addingTimeInterval(duration)
        } else {
            // RFC 5545: a date-only start with no end lasts the day; a date-time one, no time at all.
            end = allDay ? calendar(timeZone).date(byAdding: .day, value: 1, to: start) ?? start : start
        }
        if allDay, end <= start { end = calendar(timeZone).date(byAdding: .day, value: 1, to: start) ?? start }
        let title = first("SUMMARY").map { unescaped($0.value) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Event"
        return CalendarEvent(
            title: title, start: start, end: end, isAllDay: allDay,
            location: first("LOCATION").map { unescaped($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            notes: first("DESCRIPTION").map { unescaped($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            url: first("URL").flatMap { URL(string: $0.value.trimmingCharacters(in: .whitespaces)) },
            recurrence: first("RRULE")?.value)
    }

    /// `20261120` (all day), `20261120T090000Z` (UTC), `20261120T090000` with or without a `TZID`.
    static func date(_ property: Property, defaultTimeZone: TimeZone) -> (Date, isAllDay: Bool)? {
        let value = property.value.trimmingCharacters(in: .whitespaces)
        let isDateOnly = property.parameters["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))
        var zone = defaultTimeZone
        if value.hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC")!
        } else if let id = property.parameters["TZID"], let named = timeZone(named: id) {
            zone = named
        }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 8, let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        if !isDateOnly {
            guard digits.count >= 14, let hour = Int(digits.dropFirst(8).prefix(2)),
                  let minute = Int(digits.dropFirst(10).prefix(2)), let second = Int(digits.dropFirst(12).prefix(2))
            else { return nil }
            components.hour = hour
            components.minute = minute
            components.second = second
        }
        // All-day dates are days on the user's calendar, not instants somewhere else.
        guard let date = calendar(isDateOnly ? defaultTimeZone : zone).date(from: components) else { return nil }
        return (date, isDateOnly)
    }

    /// IANA names, with or without a leading "/"; failing that, the Windows names Outlook writes.
    static func timeZone(named id: String) -> TimeZone? {
        let trimmed = id.hasPrefix("/") ? String(id.dropFirst()) : id
        if let zone = TimeZone(identifier: trimmed) { return zone }
        return windowsZones[trimmed].flatMap(TimeZone.init(identifier:))
    }

    private static let windowsZones: [String: String] = [
        "Pacific Standard Time": "America/Los_Angeles",
        "Mountain Standard Time": "America/Denver",
        "US Mountain Standard Time": "America/Phoenix",
        "Central Standard Time": "America/Chicago",
        "Eastern Standard Time": "America/New_York",
        "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Atlantic Standard Time": "America/Halifax",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Chisinau",
        "FLE Standard Time": "Europe/Kiev",
        "India Standard Time": "Asia/Kolkata",
        "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "UTC": "UTC",
    ]

    /// `P1W`, `P1DT2H`, `PT1H30M`, `-PT15M` (negative durations are read as none).
    static func seconds(inDuration value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        if text.hasPrefix("+") { text = text.dropFirst() }
        guard !text.hasPrefix("-"), text.hasPrefix("P") else { return nil }
        text = text.dropFirst()
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in text {
            if character.isNumber { number.append(character); continue }
            if character == "T" { inTime = true; continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", false): total += amount * 7 * 86_400
            case ("D", false): total += amount * 86_400
            case ("H", true): total += amount * 3_600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        return number.isEmpty ? total : nil
    }

    /// `\n` and `\N` are line breaks; `\,` `\;` `\\` are the characters themselves.
    static func unescaped(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
