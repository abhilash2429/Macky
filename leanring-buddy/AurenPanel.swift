//
//  AurenPanel.swift
//  leanring-buddy
//
//  The open-notch content, ported from the Auren fork. Three stacked sections:
//
//    • Recent Activity — wired to CompanionManager.recentInteractions (the same
//      turn history the old drop panel showed), instead of AurenManager's seed.
//    • Today           — live calendar events via EventKit (AurenSidebarData).
//    • Reminders       — live incomplete reminders via EventKit, tappable to
//      mark complete.
//
//  Both EventKit sections fail safe to empty when access hasn't been granted, so
//  the panel never blocks or crashes on a fresh install.
//

import Combine
import EventKit
import SwiftUI

// MARK: - Root Panel

struct AurenPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var sidebar = AurenSidebarData()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {

                if !companionManager.recentInteractions.isEmpty {
                    PanelSection("Recent Activity") {
                        ForEach(companionManager.recentInteractions) { interaction in
                            ActivityRow(interaction: interaction)
                        }
                    }
                }

                PanelSection("Today") {
                    CalendarSection(events: sidebar.todaysEvents)
                }

                PanelSection("Reminders") {
                    RemindersSection(sidebar: sidebar)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .task { await sidebar.refresh() }
    }
}

// MARK: - Section Header Helper

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.gray)
                .textCase(.uppercase)
                .tracking(0.9)
            content()
        }
    }
}

// MARK: - Activity Row (Speed's Interaction)

struct ActivityRow: View {
    let interaction: Interaction
    /// Per-row local expansion — Interaction is immutable, so we don't need a
    /// manager round-trip just to toggle a chevron.
    @State private var isExpanded = false

    private var timeString: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: interaction.timestamp)
    }

    private var title: String {
        interaction.userPhrase.isEmpty ? interaction.modelSummary : interaction.userPhrase
    }

    /// Only the model's reply is worth revealing on expand; if the title already
    /// is the model summary (empty user phrase) there's nothing more to show.
    private var detail: String? {
        guard !interaction.userPhrase.isEmpty, !interaction.modelSummary.isEmpty else { return nil }
        return interaction.modelSummary
    }

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(timeString)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                    if detail != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                }
                if isExpanded, let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(detail == nil)
    }
}

// MARK: - Calendar Section (live)

struct CalendarSection: View {
    let events: [AurenSidebarData.CalEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty {
                Text("Nothing scheduled")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            } else {
                ForEach(events) { event in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(event.color)
                            .frame(width: 3, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Text(event.timeString)
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Reminders Section (live, tappable to complete)

struct RemindersSection: View {
    @ObservedObject var sidebar: AurenSidebarData

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if sidebar.reminders.isEmpty {
                Text("No open reminders")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            } else {
                ForEach(sidebar.reminders) { reminder in
                    Button {
                        withAnimation(.smooth(duration: 0.15)) {
                            sidebar.complete(reminder)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.gray)
                            Text(reminder.title)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Live EventKit data source

@MainActor
final class AurenSidebarData: ObservableObject {

    struct CalEvent: Identifiable {
        let id: String
        let title: String
        let timeString: String
        let color: Color
    }

    struct ReminderItem: Identifiable {
        let id: String
        let title: String
    }

    @Published private(set) var todaysEvents: [CalEvent] = []
    @Published private(set) var reminders: [ReminderItem] = []

    /// Its own store, read-only, kept separate from the tool-call integrations'
    /// stores so a UI refresh never interferes with a voice-triggered write.
    private let store = EKEventStore()

    /// Pulls today's events and open reminders. Each access is requested
    /// independently; a denial on one leaves the other section working.
    func refresh() async {
        await loadEvents()
        await loadReminders()
    }

    private func loadEvents() async {
        guard await ensureAccess(.event) else {
            todaysEvents = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        todaysEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let nsColor = event.calendar.cgColor.flatMap { NSColor(cgColor: $0) } ?? .systemBlue
                return CalEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(untitled)",
                    timeString: event.isAllDay ? "All day" : timeFormatter.string(from: event.startDate),
                    color: Color(nsColor: nsColor)
                )
            }
    }

    private func loadReminders() async {
        guard await ensureAccess(.reminder) else {
            reminders = []
            return
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }
        reminders = fetched
            .prefix(8)
            .map { ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "(untitled)") }
    }

    /// Marks a reminder complete and removes it from the list optimistically.
    func complete(_ item: ReminderItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            reminders.removeAll { $0.id == item.id }
            return
        }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reminders.removeAll { $0.id == item.id }
    }

    private func ensureAccess(_ type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                if type == .event {
                    return try await store.requestFullAccessToEvents()
                } else {
                    return try await store.requestFullAccessToReminders()
                }
            } catch {
                return false
            }
        default:
            return false
        }
    }
}