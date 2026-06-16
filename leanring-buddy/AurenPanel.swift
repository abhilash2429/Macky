//
//  AurenPanel.swift
//  leanring-buddy
//
//  The open-notch content. A persistent header (PanelHeader) pinned at the top, a
//  thin separator, then a ScrollView whose content is driven entirely by
//  CompanionManager.panelDisplayState:
//
//    • idle        — the dashboard: today's calendar, reminders, now playing,
//                    recent activity (each section hides itself when empty,
//                    except calendar which shows "No events today").
//    • modelOutput — a review card (ModelOutputCard) with Discard / Edit / Approve.
//    • fileDrop    — a drop zone (FileDropZone) collecting files to queue.
//    • connectors  — pending OAuth "Connect <App>" rows.
//    • settings    — placeholder.
//
//  The panel hugs its content height: the content is measured and published to
//  NotchUIModel.openContentHeight (clamped to [minOpenHeight, maxOpenHeight]),
//  which both the SwiftUI frame and the AppKit host window derive their open
//  height from. The overall background is pure black to blend with the notch.
//
//  EventKit-backed sections (calendar/reminders) fail safe to empty when access
//  hasn't been granted, so the panel never blocks or crashes on a fresh install.
//

import Combine
import EventKit
import SwiftUI

// MARK: - Content height measurement

/// Reports the measured height of the panel's scrolling content so the panel can
/// size itself to fit (up to maxOpenHeight).
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Root Panel

struct AurenPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @EnvironmentObject var notch: NotchUIModel
    @StateObject private var sidebar = AurenSidebarData()

    /// Header is a fixed-height bar (pinned, never scrolls). Kept in sync with
    /// PanelHeader's layout so the content-height math is correct.
    private let headerHeight: CGFloat = 40
    private var maxScroll: CGFloat { NotchConstants.maxOpenHeight - headerHeight - 1 }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(companionManager: companionManager) {
                companionManager.panelDisplayState = .idle
            }
            .frame(height: headerHeight)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .frame(maxHeight: maxScroll)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .task { await sidebar.refresh() }
        .onPreferenceChange(ContentHeightKey.self) { measured in
            let total = (headerHeight + 1 + min(measured, maxScroll)).rounded()
            let clamped = min(max(total, NotchConstants.minOpenHeight), NotchConstants.maxOpenHeight)
            if abs(notch.openContentHeight - clamped) > 0.5 {
                notch.openContentHeight = clamped
            }
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch companionManager.panelDisplayState {
        case .idle:
            idleContent
        case let .modelOutput(text, type):
            ModelOutputCard(content: text, type: type, companionManager: companionManager)
        case let .fileDrop(files):
            FileDropZone(files: files, companionManager: companionManager)
        case .connectors:
            connectorsContent
        case .settings:
            settingsContent
        }
    }

    // MARK: - Idle dashboard

    private var todayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Today · \(f.string(from: Date()))"
    }

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            // 1. Calendar — always present; "No events today" when empty.
            PanelSection(todayTitle) {
                CalendarSection(events: sidebar.todaysEvents)
            }

            // 2. Reminders — hidden entirely when there are none.
            if !sidebar.reminders.isEmpty {
                PanelSection("Reminders") {
                    RemindersSection(sidebar: sidebar)
                }
            }

            // 3. Now Playing — only while there's active playback.
            if let nowPlaying = companionManager.nowPlaying {
                PanelSection("Now Playing") {
                    NowPlayingChip(state: nowPlaying)
                }
            }

            // 4. Recent Activity — last 4 turns; hidden when empty.
            if !companionManager.recentInteractions.isEmpty {
                PanelSection("Recent Activity") {
                    ForEach(companionManager.recentInteractions.prefix(4)) { interaction in
                        ActivityRow(interaction: interaction)
                    }
                }
            }
        }
    }

    // MARK: - Connectors / Settings surfaces

    @ViewBuilder
    private var connectorsContent: some View {
        if companionManager.pendingConnections.isEmpty {
            placeholder("No connections to set up right now.")
        } else {
            PanelSection("Connect Accounts") {
                ForEach(companionManager.pendingConnections) { connection in
                    ConnectAccountRow(
                        connection: connection,
                        onConnect: { companionManager.openPendingConnection(connection) },
                        onDismiss: { companionManager.dismissPendingConnection(connection) }
                    )
                }
            }
        }
    }

    private var settingsContent: some View {
        placeholder("Settings — coming soon")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(DS.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(0.9)
            content()
        }
    }
}

// MARK: - Connect Account Row (Composio pending OAuth)

/// One "Connect <App>" row: the toolkit name, an accent "Connect" pill that opens
/// the OAuth link, and a small "x" to dismiss.
private struct ConnectAccountRow: View {
    let connection: PendingConnection
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(connection.toolkit.capitalized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DS.Spacing.xs)

            Button(action: onConnect) {
                Text("Connect")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
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
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(timeString)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                    if detail != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }
                if isExpanded, let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(DS.Colors.surface1))
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
                Text("No events today")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
            } else {
                ForEach(events) { event in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(event.color)
                            .frame(width: 3, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(event.timeString)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Colors.textSecondary)
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
            ForEach(sidebar.reminders) { reminder in
                Button {
                    withAnimation(.smooth(duration: 0.15)) {
                        sidebar.complete(reminder)
                    }
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(reminder.isOverdue ? DS.Colors.warning : DS.Colors.textTertiary)
                        Text(reminder.title)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let due = reminder.dueString {
                            Text(due)
                                .font(.system(size: 10))
                                .foregroundStyle(reminder.isOverdue ? DS.Colors.warningText : DS.Colors.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Now Playing chip

private struct NowPlayingChip: View {
    let state: CompanionManager.NowPlayingState

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = state.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
        } else {
            RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                .fill(DS.Colors.surface2)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Colors.textTertiary)
                )
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
        let dueDate: Date?

        var isOverdue: Bool {
            guard let dueDate else { return false }
            return dueDate < Date()
        }

        /// Short due label ("Jun 16", "2:30 PM" same day), or nil when undated.
        var dueString: String? {
            guard let dueDate else { return nil }
            let f = DateFormatter()
            if Calendar.current.isDateInToday(dueDate) {
                f.timeStyle = .short
                f.dateStyle = .none
            } else {
                f.dateFormat = "MMM d"
            }
            return f.string(from: dueDate)
        }
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
            .map { reminder in
                let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                return ReminderItem(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "(untitled)",
                    dueDate: due
                )
            }
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
