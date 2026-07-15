//
//  CalendarIntegration.swift
//  leanring-buddy
//
//  Milestone 9: the three Apple Calendar function tools the model can call —
//  read a day's events, create an event, and find a free time slot. All backed
//  by EventKit through a single shared EKEventStore (creating one per call is
//  wasteful and re-triggers internal setup). The app is not sandboxed, so the
//  only requirement beyond the NSCalendarsUsageDescription string is the user
//  granting access at the first TCC prompt.
//
//  Like SystemControlsIntegration, the action methods are stateless statics;
//  RealtimeClient registers thin tool handlers that await them. Thrown errors
//  surface to the model as {"error": <message>} via dispatchFunctionCall, so the
//  permission error is phrased for the model to read aloud.
//

import EventKit
import Foundation

enum CalendarIntegration {

    /// One shared store for the whole app (per Milestone 9 decision). EKEventStore
    /// is cheap to keep around and expensive to recreate.
    private static let eventStore = EKEventStore()

    /// Bookable window for find_free_slot: 09:00–18:00 local time.
    private static let workdayStartHour = 9
    private static let workdayEndHour = 18

    // MARK: - Read events

    /// Returns the events scheduled on `dateString` (an ISO date or "today"/
    /// "tomorrow"/"yesterday"). Empty list when nothing is scheduled.
    static func getEvents(dateString: String) async throws -> String {
        try await ensureAccess()
        guard let dayStart = parseDay(dateString) else {
            throw CalendarError.invalidDate
        }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!

        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let eventDictionaries: [[String: Any]] = events.map { event in
            var dictionary: [String: Any] = [
                "title": event.title ?? "(untitled)",
                "start": timeString(event.startDate),
                "end": timeString(event.endDate),
                "allDay": event.isAllDay
            ]
            if let location = event.location, !location.isEmpty {
                dictionary["location"] = location
            }
            return dictionary
        }

        return jsonString([
            "date": dayString(dayStart),
            "events": eventDictionaries
        ])
    }

    // MARK: - Create event

    /// Creates a calendar event on the default calendar. `startDateString` and
    /// `endDateString` are datetimes (ISO8601 or "yyyy-MM-dd HH:mm").
    static func createEvent(
        title: String,
        startDateString: String,
        endDateString: String,
        notes: String?
    ) async throws -> String {
        try await ensureAccess()
        guard let start = parseDateTime(startDateString),
              let end = parseDateTime(endDateString) else {
            throw CalendarError.invalidDate
        }
        guard end > start else {
            throw CalendarError.invalidRange
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar

        try eventStore.save(event, span: .thisEvent)

        return jsonString([
            "status": "created",
            "title": title,
            "start": dateTimeString(start),
            "end": dateTimeString(end)
        ])
    }

    // MARK: - Find free slot

    /// Finds the first gap of at least `durationMinutes` within the 09:00–18:00
    /// window on `dateString`, ignoring all-day events.
    static func findFreeSlot(dateString: String, durationMinutes: Int) async throws -> String {
        try await ensureAccess()
        guard durationMinutes > 0 else {
            throw CalendarError.invalidRange
        }
        guard let dayStart = parseDay(dateString) else {
            throw CalendarError.invalidDate
        }

        let calendar = Calendar.current
        guard let windowStart = calendar.date(bySettingHour: workdayStartHour, minute: 0, second: 0, of: dayStart),
              let windowEnd = calendar.date(bySettingHour: workdayEndHour, minute: 0, second: 0, of: dayStart) else {
            throw CalendarError.invalidDate
        }

        // Only timed events inside the bookable window can block a slot.
        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let busyEvents = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        let duration = TimeInterval(durationMinutes * 60)
        var cursor = windowStart
        for event in busyEvents {
            // A gap before this event that's big enough wins.
            if event.startDate.timeIntervalSince(cursor) >= duration {
                break
            }
            // Otherwise advance past it (events may overlap, so take the max).
            cursor = max(cursor, event.endDate)
        }

        guard cursor.addingTimeInterval(duration) <= windowEnd else {
            return jsonString(["status": "no free slot found"])
        }
        let slotEnd = cursor.addingTimeInterval(duration)
        return jsonString([
            "freeSlot": [
                "start": dateTimeString(cursor),
                "end": dateTimeString(slotEnd)
            ]
        ])
    }

    // MARK: - Access

    /// Ensures the app has full calendar access, prompting once if undetermined.
    /// Throws a voice-friendly error otherwise so the model can ask the user to
    /// grant access in System Settings.
    private static func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await eventStore.requestFullAccessToEvents()
            if !granted {
                throw CalendarError.accessDenied
            }
        default:
            throw CalendarError.accessDenied
        }
    }

    // MARK: - Date parsing

    /// Resolves a day-granularity input: the words today/tomorrow/yesterday
    /// (the M13 system prompt that would tell the model the date isn't wired
    /// yet), otherwise a parsed datetime reduced to the start of its day.
    private static func parseDay(_ string: String) -> Date? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        switch normalized {
        case "today":
            return calendar.startOfDay(for: Date())
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
        default:
            guard let date = parseDateTime(string) else { return nil }
            return calendar.startOfDay(for: date)
        }
    }

    /// Parses a datetime: ISO8601 first (with and without fractional seconds),
    /// then "yyyy-MM-dd HH:mm", then date-only "yyyy-MM-dd".
    private static func parseDateTime(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - Formatting

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Encodes a result via JSONSerialization so values like event titles that
    /// contain quotes can't corrupt the JSON sent back to the model.
    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"failed to encode calendar result\"}"
        }
        return string
    }
}

enum CalendarError: LocalizedError {
    case accessDenied
    case invalidDate
    case invalidRange
    case noDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "I need Calendar access — please enable it in System Settings under Privacy & Security, then Calendars."
        case .invalidDate:
            return "I couldn't understand that date."
        case .invalidRange:
            return "The end time needs to be after the start time."
        case .noDefaultCalendar:
            return "There's no default calendar to add the event to."
        }
    }
}
