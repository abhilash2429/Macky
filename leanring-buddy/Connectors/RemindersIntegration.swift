//
//  RemindersIntegration.swift
//  leanring-buddy
//
//  Milestone 10: the create_reminder function tool, backed by EventKit. Creates
//  a reminder on the user's default Reminders list, optionally with a due date
//  (which also gets an alarm so it actually notifies). Mirrors the structure of
//  SystemControlsIntegration / CalendarIntegration: stateless statics, JSON
//  results, and a voice-friendly permission error that the model reads aloud.
//
//  Uses its own EKEventStore rather than reaching into CalendarIntegration's
//  (kept private there). Two stores are independent but harmless; this keeps the
//  files decoupled.
//
//  Note: under the app's hardened runtime, reminders access requires the
//  com.apple.security.personal-information.reminders entitlement in addition to
//  the NSRemindersUsageDescription string — without it the request fails
//  silently with no prompt (same gotcha hit by calendar in M9).
//

import EventKit
import Foundation

enum RemindersIntegration {

    private static let eventStore = EKEventStore()

    /// Creates a reminder on the default Reminders list. `dueDateString` is an
    /// optional ISO8601 datetime; when present it sets the due date and adds an
    /// alarm so the reminder fires at that time.
    static func createReminder(
        title: String,
        dueDateString: String?,
        notes: String?
    ) async throws -> String {
        try await ensureAccess()
        guard let list = eventStore.defaultCalendarForNewReminders() else {
            throw RemindersError.noDefaultList
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = list

        var dueDescription = "no due date"
        let trimmedDue = dueDateString?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDue, !trimmedDue.isEmpty {
            guard let dueDate = parseDateTime(trimmedDue) else {
                throw RemindersError.invalidDate
            }
            // Reminders use date components (Gregorian, or EventKit errors), plus
            // an absolute-date alarm so the reminder actually notifies on time.
            reminder.dueDateComponents = Calendar(identifier: .gregorian).dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            dueDescription = dateTimeString(dueDate)
        }

        try eventStore.save(reminder, commit: true)

        return jsonString([
            "status": "created",
            "title": title,
            "due": dueDescription
        ])
    }

    // MARK: - Access

    /// Ensures reminders access, prompting once if undetermined. Throws a
    /// voice-friendly error otherwise so the model can ask the user to grant it.
    private static func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .writeOnly:
            return
        case .notDetermined:
            let granted = try await eventStore.requestFullAccessToReminders()
            if !granted {
                throw RemindersError.accessDenied
            }
        default:
            throw RemindersError.accessDenied
        }
    }

    // MARK: - Date parsing & formatting

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

    private static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Encodes via JSONSerialization so a title containing quotes can't corrupt
    /// the JSON sent back to the model.
    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"failed to encode reminder result\"}"
        }
        return string
    }
}

enum RemindersError: LocalizedError {
    case accessDenied
    case invalidDate
    case noDefaultList

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "I need Reminders access — please enable it in System Settings under Privacy & Security, then Reminders."
        case .invalidDate:
            return "I couldn't understand that due date."
        case .noDefaultList:
            return "There's no default Reminders list to add to."
        }
    }
}
