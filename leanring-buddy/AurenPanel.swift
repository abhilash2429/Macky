//
//  AurenPanel.swift
//  leanring-buddy
//
//  Expanded notch panel content for Macky. The filename is kept for now per the
//  project constraint, but all visible UI is Macky-branded and notch-first.
//

import AppKit
import Carbon
import Combine
import EventKit
import SwiftUI

enum MackyPanelPage {
    case home
    case connectors
    case settings
}

struct AurenPanel: View {
    @ObservedObject var companionManager: CompanionManager
    let page: MackyPanelPage
    @StateObject private var sidebar = AurenSidebarData()
    @StateObject private var music = MackyMusicManager()

    var body: some View {
        Group {
            switch page {
            case .home:
                home
            case .connectors:
                ConnectorsPanel(companionManager: companionManager)
            case .settings:
                SettingsPanel(companionManager: companionManager)
            }
        }
        .task {
            await sidebar.refresh()
        }
    }

    private var home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                if companionManager.isAssistantActive {
                    AssistantActivityCard(companionManager: companionManager)
                }

                HStack(alignment: .top, spacing: 14) {
                    // LEFT — music on top, recent activity (history) below it.
                    VStack(alignment: .leading, spacing: 14) {
                        BoringStyleMusicCard(music: music)

                        if !companionManager.recentInteractions.isEmpty {
                            PanelSection("Recent Activity") {
                                ForEach(companionManager.recentInteractions.prefix(3)) { interaction in
                                    ActivityRow(interaction: interaction)
                                }
                            }
                        }
                    }
                    .frame(width: 330)

                    // RIGHT — calendar and reminders.
                    VStack(alignment: .leading, spacing: 12) {
                        CalendarCard(sidebar: sidebar)
                        RemindersCard(sidebar: sidebar)
                    }
                }

                if !companionManager.pendingConnections.isEmpty {
                    PanelSection("Connect Accounts") {
                        ForEach(companionManager.pendingConnections) { connection in
                            PendingConnectionRow(
                                connection: connection,
                                onConnect: { companionManager.openPendingConnection(connection) },
                                onDismiss: { companionManager.dismissPendingConnection(connection) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
    }
}

private struct AssistantActivityCard: View {
    @ObservedObject var companionManager: CompanionManager

    /// Bundled logo for the connector whose MCP call is running, if any resolves.
    private var connectorLogo: NSImage? {
        guard let name = companionManager.activeConnectorToolCall?.logoAssetName else { return nil }
        return NSImage(named: name)
    }

    var body: some View {
        HStack(spacing: 10) {
            // While a registered connector's MCP call runs, its logo stands in for the
            // waveform; otherwise the usual voice-activity waveform is shown.
            if let connectorLogo {
                Image(nsImage: connectorLogo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(3)
                    .frame(width: 24, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                VoiceActivityView(companionManager: companionManager, realtimeClient: companionManager.realtimeClient)
                    .frame(width: 24, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(companionManager.activeStatusText.isEmpty ? "Ready" : companionManager.activeStatusText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Macky is working in the notch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }
}

private struct BoringStyleMusicCard: View {
    @ObservedObject var music: MackyMusicManager
    @State private var isDragging = false
    @State private var sliderValue: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            albumArt
                .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 10) {
                songInfo
                TimelineView(.animation(minimumInterval: music.isPlaying ? 0.5 : nil)) { _ in
                    progressSlider
                }
                controlToolbar

                Button {
                    music.openActiveMusicApp()
                } label: {
                    Label(music.activeAppName, systemImage: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // Same flat surface as the Calendar/Reminders cards so the home page reads
        // as one cohesive panel instead of a distinct, album-tinted left container.
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .onReceive(music.$elapsedTime) { elapsedTime in
            if !isDragging {
                sliderValue = elapsedTime
            }
        }
        .onAppear { music.startPolling() }
        .onDisappear { music.stopPolling() }
    }

    private var albumArt: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: music.albumArt)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(music.isPlaying ? 1 : 0.92)
                .animation(.smooth(duration: 0.24), value: music.isPlaying)

            if !music.isPlaying {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.38))
            }

            Image(nsImage: music.activeAppIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .padding(5)
                .background(Circle().fill(Color.black.opacity(0.78)))
                .offset(x: 8, y: 8)
        }
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(music.artist)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
            Text(music.album)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(1)
        }
    }

    private var progressSlider: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { music.duration > 0 ? min(isDragging ? sliderValue : music.currentElapsedTime, music.duration) : 0 },
                    set: { sliderValue = $0 }
                ),
                in: 0...max(music.duration, 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        music.seek(to: sliderValue)
                    }
                }
            )
            .controlSize(.mini)
            .tint(.white)

            HStack {
                Text(music.timeString(from: music.currentElapsedTime))
                Spacer()
                Text(music.timeString(from: music.duration))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
        }
    }

    private var controlToolbar: some View {
        HStack(spacing: 7) {
            MusicButton(icon: "shuffle", isActive: music.isShuffled) { music.toggleShuffle() }
            MusicButton(icon: "backward.fill") { music.previous() }
            MusicButton(icon: music.isPlaying ? "pause.fill" : "play.fill", isPrimary: true) { music.togglePlay() }
            MusicButton(icon: "forward.fill") { music.next() }
            MusicButton(icon: music.repeatIcon, isActive: music.isRepeatEnabled) { music.toggleRepeat() }
        }
    }
}

private struct MusicButton: View {
    let icon: String
    var isPrimary = false
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: isPrimary ? 15 : 12, weight: .semibold))
                .foregroundStyle(isPrimary ? .black : (isActive ? .red : .white))
                .frame(width: isPrimary ? 34 : 26, height: isPrimary ? 34 : 26)
                .background(Circle().fill(isPrimary ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct CalendarCard: View {
    @ObservedObject var sidebar: AurenSidebarData
    @State private var selectedDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Month + year on one line above the day wheel so the narrow right
            // column can't squeeze "Jun"/"2026" into a wrapped two-line stack.
            Text("\(selectedDate.formatted(.dateTime.month(.abbreviated))) \(selectedDate.formatted(.dateTime.year()))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            MackyDateWheel(selectedDate: $selectedDate)
                .frame(maxWidth: .infinity, alignment: .leading)

            if sidebar.selectedEvents.isEmpty {
                EmptyPanelLine(
                    icon: "calendar.badge.checkmark",
                    title: Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events"
                )
            } else {
                ForEach(sidebar.selectedEvents.prefix(3)) { event in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(event.color)
                            .frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                            Text(event.timeString)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .task { await sidebar.loadEvents(for: selectedDate) }
        .onChange(of: selectedDate) { _, newDate in
            Task { await sidebar.loadEvents(for: newDate) }
        }
    }
}

private struct MackyDateWheel: View {
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?

    private let days: [Date] = {
        let calendar = Calendar.current
        return (-7...14).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
    }()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)
                    let isToday = Calendar.current.isDateInToday(day)
                    Button {
                        selectedDate = day
                        withAnimation(.smooth(duration: 0.2)) {
                            scrollPosition = index
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 8, weight: .medium))
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(isSelected ? .white : Color(white: isToday ? 0.92 : 0.62))
                        .frame(width: 25, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .frame(width: 178, height: 44)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)
        .onAppear {
            selectedDate = Date()
            scrollPosition = 7
        }
    }
}

private struct RemindersCard: View {
    @ObservedObject var sidebar: AurenSidebarData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminders")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)

            if sidebar.reminders.isEmpty {
                EmptyPanelLine(icon: "checklist", title: "No open reminders")
            } else {
                ForEach(sidebar.reminders.prefix(4)) { reminder in
                    Button {
                        withAnimation(.smooth(duration: 0.16)) {
                            sidebar.complete(reminder)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 12))
                            Text(reminder.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                        }
                        .foregroundStyle(.white.opacity(0.82))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

private struct EmptyPanelLine: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
        }
        .frame(height: 28)
    }
}

private struct ConnectorsPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var filteredConnectors: [MackyConnector] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return MackyConnectorCatalog.items }
        return MackyConnectorCatalog.items.filter {
            $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar

            HStack(spacing: 10) {
                Text("Connectors")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))

                Spacer()

                ConnectorFilterChip(title: "Filter by")
                ConnectorFilterChip(title: "Sort by")
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredConnectors) { connector in
                        ConnectorGridCard(
                            connector: connector,
                            pendingConnection: pendingConnection(for: connector),
                            isConnected: companionManager.connectedToolkits.contains(connector.slug.lowercased()),
                            onConnect: { companionManager.requestConnectorConnection(slug: connector.slug) },
                            onOpenPending: { companionManager.openPendingConnection($0) }
                        )
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .onAppear { companionManager.refreshConnectedToolkits() }
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Search connectors…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func pendingConnection(for connector: MackyConnector) -> PendingConnection? {
        let connectorSlug = normalizedConnectorKey(connector.slug)
        let connectorName = normalizedConnectorKey(connector.name)
        return companionManager.pendingConnections.first {
            let toolkit = normalizedConnectorKey($0.toolkit)
            return toolkit == connectorSlug || toolkit == connectorName
        }
    }

    private func normalizedConnectorKey(_ rawValue: String) -> String {
        rawValue
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private struct ConnectorFilterChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

private enum ConnectorBadge {
    case new
    case popular(Int)
    case none
}

private struct MackyConnector: Identifiable {
    let id: String
    let name: String
    let slug: String
    let icon: String
    let category: String
    let description: String
    let accent: Color
    let badge: ConnectorBadge
    let examples: [String]
}

/// UI-only metadata for a connector card, layered on top of the shared identity
/// (slug / display name / logo) owned by `ConnectorRegistry`. Keyed by toolkit slug so
/// the grid's slug and name come from the registry — the two lists can no longer drift.
private struct ConnectorCardMeta {
    let slug: String
    let icon: String
    let category: String
    let description: String
    let accent: Color
    let badge: ConnectorBadge
    let examples: [String]
}

private enum MackyConnectorCatalog {
    /// UI metadata per connector slug. The slug, display name, and logo come from
    /// `ConnectorRegistry`; only the presentation extras live here.
    private static let meta: [ConnectorCardMeta] = [
        ConnectorCardMeta(
            slug: "gmail",
            icon: "envelope.fill",
            category: "Communication",
            description: "Draft, send, search, and summarize email from voice requests.",
            accent: Color(hex: "#EA4335"),
            badge: .popular(2),
            examples: ["Write a follow-up to John", "Find the latest client email", "Summarize unread mail"]
        ),
        ConnectorCardMeta(
            slug: "slack",
            icon: "number",
            category: "Communication",
            description: "Send messages, look up channels, and turn threads into next actions.",
            accent: Color(hex: "#36C5F0"),
            badge: .popular(9),
            examples: ["Send the standup update", "Catch me up on design", "Post a reminder"]
        ),
        ConnectorCardMeta(
            slug: "googlecalendar",
            icon: "calendar",
            category: "Planning",
            description: "Create meetings and inspect availability through Composio.",
            accent: Color(hex: "#34A853"),
            badge: .popular(3),
            examples: ["Schedule a call tomorrow", "Move my 3 PM meeting", "Find open time Friday"]
        ),
        ConnectorCardMeta(
            slug: "notion",
            icon: "doc.text.fill",
            category: "Knowledge",
            description: "Create pages, update notes, and pull workspace context into Macky.",
            accent: Color.white.opacity(0.92),
            badge: .popular(6),
            examples: ["Add this to product notes", "Find the launch checklist", "Create a meeting page"]
        ),
        ConnectorCardMeta(
            slug: "github",
            icon: "chevron.left.forwardslash.chevron.right",
            category: "Developer",
            description: "Read issues, create pull requests, and work with repositories.",
            accent: Color(hex: "#A78BFA"),
            badge: .new,
            examples: ["Open a bug issue", "Summarize recent PRs", "Find failing checks"]
        ),
        ConnectorCardMeta(
            slug: "linear",
            icon: "line.3.horizontal.decrease.circle.fill",
            category: "Planning",
            description: "Create issues, inspect cycles, and keep project status moving.",
            accent: Color(hex: "#5E6AD2"),
            badge: .new,
            examples: ["Create a task for this", "Move it to in progress", "List urgent bugs"]
        ),
        ConnectorCardMeta(
            slug: "spotify",
            icon: "music.note",
            category: "Media",
            description: "Control playback and use music context without leaving the notch.",
            accent: Color(hex: "#1DB954"),
            badge: .popular(4),
            examples: ["Play focus music", "Pause Spotify", "Skip this track"]
        )
    ]

    /// The grid's connectors, built by joining each `ConnectorRegistry` identity with its
    /// UI metadata. A slug present in the registry but missing metadata still appears (with
    /// a default icon); metadata for an unknown slug is skipped — so the grid and the
    /// logo-swap always agree on the connector set.
    static let items: [MackyConnector] = ConnectorRegistry.connectors.map { identity in
        let meta = meta.first { $0.slug == identity.slug }
        return MackyConnector(
            id: identity.slug,
            name: identity.displayName,
            slug: identity.slug,
            icon: meta?.icon ?? "app.connected.to.app.below.fill",
            category: meta?.category ?? "Apps",
            description: meta?.description ?? "Connect \(identity.displayName) to use it by voice.",
            accent: meta?.accent ?? Color.white.opacity(0.9),
            badge: meta?.badge ?? .none,
            examples: meta?.examples ?? []
        )
    }
}

private struct ConnectorGridCard: View {
    let connector: MackyConnector
    let pendingConnection: PendingConnection?
    let isConnected: Bool
    let onConnect: () -> Void
    let onOpenPending: (PendingConnection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ConnectorIcon(connector: connector, size: 44, iconSize: 20)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(connector.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    badge
                }
                .padding(.top, 4)

                Spacer(minLength: 0)

                actionButton
            }

            Text(connector.description)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var badge: some View {
        switch connector.badge {
        case .new:
            Text("New")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#E8845C"))
        case .popular(let rank):
            Text("#\(rank) popular")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isConnected {
            // Live, end-to-end connection: show a tick, no action needed.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DS.Colors.success)
                .frame(width: 30, height: 30)
                .help("\(connector.name) is connected")
        } else {
            Button {
                if let pendingConnection {
                    onOpenPending(pendingConnection)
                } else {
                    onConnect()
                }
            } label: {
                Image(systemName: pendingConnection != nil ? "arrow.triangle.2.circlepath" : "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(pendingConnection != nil ? DS.Colors.accentText : .white.opacity(0.65))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pendingConnection != nil ? "Open authorization link" : "Connect \(connector.name)")
        }
    }
}

private struct ConnectorIcon: View {
    let connector: MackyConnector
    let size: CGFloat
    let iconSize: CGFloat

    /// Bundled official brand logo for this toolkit, if one ships in the catalog.
    private var logoImage: NSImage? {
        NSImage(named: "ConnectorLogo-\(connector.slug)")
    }

    var body: some View {
        let corner = min(14, size * 0.28)
        Group {
            if let logoImage {
                // Official logo on a white tile so dark logos (Notion, GitHub) and
                // multicolor logos alike stay crisp and legible on the dark panel.
                Image(nsImage: logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.18)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
            } else {
                // Fallback: accent-tinted SF Symbol (e.g. a toolkit with no bundled logo).
                Image(systemName: connector.icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(connector.accent)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(connector.accent.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(connector.accent.opacity(0.22), lineWidth: 1)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct SettingsPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var authManager = AuthManager.shared
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab: String, CaseIterable {
        case general = "General"
        case permissions = "Permissions"
        case shortcuts = "Shortcuts"
        case account = "Account"

        var icon: String {
            switch self {
            case .general: return "gear"
            case .permissions: return "hand.raised.fill"
            case .shortcuts: return "keyboard"
            case .account: return "person.crop.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                MackyLogoView(size: 46)
                    .padding(.leading, 6)
                    .padding(.bottom, 14)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16)
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTab == tab ? Color.white.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 150, alignment: .topLeading)
            .padding(.top, 10)

            Divider().background(Color.white.opacity(0.12))

            ScrollView(.vertical, showsIndicators: false) {
                settingsDetail
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedTab {
        case .general:
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle("General", subtitle: "Panel, status, and active-state controls.")
                SettingsInfoRow(icon: "capsule.portrait.fill", title: "Notch UI", value: "Enabled")
                SettingsInfoRow(icon: "waveform", title: "Active state", value: companionManager.activeStatusText.isEmpty ? "Idle" : companionManager.activeStatusText)
                SettingsInfoRow(icon: "puzzlepiece.extension.fill", title: "Connectors", value: "\(companionManager.pendingConnections.count) pending")
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 10) {
                PanelTitle("Permissions", subtitle: "Grant access without leaving the panel flow.")
                SettingsPermissionRow(title: "Microphone", granted: companionManager.hasMicrophonePermission) {
                    companionManager.requestMicrophonePermission()
                }
                SettingsPermissionRow(title: "Screen Recording", granted: companionManager.hasScreenRecordingPermission) {
                    companionManager.requestScreenRecordingPermission()
                }
                SettingsPermissionRow(title: "Screen Content", granted: companionManager.hasScreenContentPermission) {
                    companionManager.requestScreenContentPermission()
                }
                SettingsPermissionRow(title: "Accessibility", granted: companionManager.hasAccessibilityPermission) {
                    companionManager.requestAccessibilityPermission()
                }
                SettingsPermissionRow(title: "Calendar", granted: companionManager.hasCalendarPermission) {
                    companionManager.requestCalendarPermission()
                }
                SettingsPermissionRow(title: "Reminders", granted: companionManager.hasRemindersPermission) {
                    companionManager.requestRemindersPermission()
                }
                SettingsPermissionRow(title: "Automation", granted: companionManager.hasAutomationPermission) {
                    companionManager.requestAutomationPermission()
                }
            }
        case .shortcuts:
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle("Shortcuts", subtitle: "Push-to-talk listens globally while Macky is running.")
                HotkeySettingsView(companionManager: companionManager)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
        case .account:
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle("Account", subtitle: "Session and app controls.")
                Button("Reset onboarding") {
                    companionManager.setPanelOnboardingComplete(false)
                }
                .mackySettingsButton()

                Button("Sign out") {
                    authManager.clearSession()
                    companionManager.setPanelOnboardingComplete(false)
                }
                .mackySettingsButton()

                Button("Quit Macky") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
            }
        }
    }
}

private struct SettingsInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.46))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
    }
}

private extension View {
    func mackySettingsButton() -> some View {
        self
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.white.opacity(0.72))
            Spacer()
            Button(granted ? "Granted" : "Grant") { action() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted ? .white.opacity(0.38) : .black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(granted ? Color.white.opacity(0.08) : Color.white))
                .disabled(granted)
        }
    }
}

private struct PanelTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.52))
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
            content()
        }
    }
}

private struct PendingConnectionRow: View {
    let connection: PendingConnection
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(connection.toolkit.capitalized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button("Open link", action: onConnect)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
    }
}

struct ActivityRow: View {
    let interaction: Interaction
    @State private var isExpanded = false

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: interaction.timestamp)
    }

    private var title: String {
        interaction.userPhrase.isEmpty ? interaction.modelSummary : interaction.userPhrase
    }

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
                    Spacer()
                    Text(timeString)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                }
                if isExpanded, let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
        }
        .buttonStyle(.plain)
        .disabled(detail == nil)
    }
}

@MainActor
final class MackyMusicManager: ObservableObject {
    @Published var title = "Nothing playing"
    @Published var artist = "Spotify or Music"
    @Published var album = "Open a player to control it here"
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var elapsedTime: Double = 0
    @Published var timestampDate = Date()
    @Published var playbackRate: Double = 0
    @Published var isShuffled = false
    @Published var repeatMode = "off"
    @Published var activeAppName = "Music"
    @Published var activeBundleIdentifier = "com.apple.Music"
    @Published var activeAppIcon: NSImage = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")
    @Published var albumArt: NSImage = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")!

    private let placeholderArt = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album Art")!
    private var lastArtworkURL: String?
    private var pollTimer: Timer?

    /// Keeps the panel in sync with whatever the player is doing. Polling is the
    /// only way the panel reflects a track the user starts *after* opening it, and
    /// it also lets the first Apple event reach Spotify/Music so macOS can show the
    /// one-time Automation permission prompt.
    func startPolling() {
        Task { @MainActor in await refresh() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    var currentElapsedTime: Double {
        guard isPlaying else { return elapsedTime }
        return min(max(elapsedTime + Date().timeIntervalSince(timestampDate) * playbackRate, 0), duration)
    }

    var isRepeatEnabled: Bool { repeatMode != "off" }

    var repeatIcon: String {
        repeatMode == "one" ? "repeat.1" : "repeat"
    }

    func refresh() async {
        if await updateFromSpotify() { return }
        if await updateFromMusic() { return }
        title = "Nothing playing"
        artist = "Spotify or Music"
        album = "Open a player to control it here"
        isPlaying = false
        duration = 0
        elapsedTime = 0
        playbackRate = 0
        activeBundleIdentifier = "com.apple.Music"
        activeAppName = "Music"
        activeAppIcon = icon(forBundleIdentifier: activeBundleIdentifier)
        lastArtworkURL = nil
        albumArt = placeholderArt
    }

    func togglePlay() {
        // Optimistic flip so the button reacts instantly; the player state query
        // right after a playpause command often still reports the old value.
        isPlaying.toggle()
        playbackRate = isPlaying ? 1 : 0
        timestampDate = Date()
        runScript(command: "playpause", in: activeAppName)
        refreshAfterCommand()
    }

    func next() {
        runScript(command: "next track", in: activeAppName)
        refreshAfterCommand()
    }

    func previous() {
        runScript(command: "previous track", in: activeAppName)
        refreshAfterCommand()
    }

    /// Player state lags a beat after a transport command, so re-read once now and
    /// again shortly after to settle on the real values.
    private func refreshAfterCommand() {
        Task { @MainActor in
            await refresh()
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        }
    }

    func toggleShuffle() {
        if activeAppName == "Spotify" {
            runScriptDetached("tell application \"Spotify\" to set shuffling to not shuffling")
        }
        Task { @MainActor in await refresh() }
    }

    func toggleRepeat() {
        if activeAppName == "Spotify" {
            runScriptDetached("tell application \"Spotify\" to set repeating to not repeating")
        } else {
            let targetMode = repeatMode == "off" ? "all" : "off"
            runScriptDetached("tell application \"Music\" to set song repeat to \(targetMode)")
        }
        Task { @MainActor in await refresh() }
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        if activeAppName == "Spotify" {
            runScriptDetached("tell application \"Spotify\" to set player position to \(seconds)")
        } else {
            runScriptDetached("tell application \"Music\" to set player position to \(seconds)")
        }
        elapsedTime = seconds
        timestampDate = Date()
    }

    func openActiveMusicApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activeBundleIdentifier) {
            NSWorkspace.shared.open(appURL)
        }
    }

    func timeString(from seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func updateFromSpotify() async -> Bool {
        guard isRunning(bundleIdentifier: "com.spotify.client") else { return false }

        // One Apple event instead of nine. `try` guards the cases where there is no
        // current track (ad, podcast boundary) so a single missing field can't drop
        // the whole read back to the "Spotify / Ready" placeholder state.
        let script = """
        tell application "Spotify"
            set _state to player state as string
            set _pos to player position as string
            set _shuffle to shuffling as string
            set _repeat to repeating as string
            set _name to ""
            set _artist to ""
            set _album to ""
            set _dur to "0"
            set _art to ""
            try
                set _name to name of current track
                set _artist to artist of current track
                set _album to album of current track
                set _dur to duration of current track as string
                set _art to artwork url of current track
            end try
            return _state & "\t" & _name & "\t" & _artist & "\t" & _album & "\t" & _dur & "\t" & _pos & "\t" & _shuffle & "\t" & _repeat & "\t" & _art
        end tell
        """
        guard let fields = await scriptValues(script, expected: 9) else {
            // The script failed even though Spotify is running — almost always the
            // Automation permission. Explicitly ask macOS for it so the system prompt
            // appears (a bare NSAppleScript call can fail silently without prompting).
            requestAutomationPermission(forBundleIdentifier: "com.spotify.client")
            return false
        }

        activeAppName = "Spotify"
        activeBundleIdentifier = "com.spotify.client"
        activeAppIcon = icon(forBundleIdentifier: activeBundleIdentifier)
        isPlaying = fields[0] == "playing"
        title = fields[1].isEmpty ? "Spotify" : fields[1]
        artist = fields[2].isEmpty ? "Ready" : fields[2]
        album = fields[3]
        duration = (Double(fields[4]) ?? 0) / 1000
        elapsedTime = Double(fields[5]) ?? 0
        timestampDate = Date()
        playbackRate = isPlaying ? 1 : 0
        isShuffled = fields[6] == "true"
        repeatMode = fields[7] == "true" ? "all" : "off"
        updateArtwork(from: fields[8])
        return true
    }

    private func updateFromMusic() async -> Bool {
        guard isRunning(bundleIdentifier: "com.apple.Music") else { return false }

        let script = """
        tell application "Music"
            set _state to player state as string
            set _pos to player position as string
            set _repeat to song repeat as string
            set _name to ""
            set _artist to ""
            set _album to ""
            set _dur to "0"
            try
                set _name to name of current track
                set _artist to artist of current track
                set _album to album of current track
                set _dur to duration of current track as string
            end try
            return _state & "\t" & _name & "\t" & _artist & "\t" & _album & "\t" & _dur & "\t" & _pos & "\t" & _repeat
        end tell
        """
        guard let fields = await scriptValues(script, expected: 7) else {
            requestAutomationPermission(forBundleIdentifier: "com.apple.Music")
            return false
        }

        activeAppName = "Music"
        activeBundleIdentifier = "com.apple.Music"
        activeAppIcon = icon(forBundleIdentifier: activeBundleIdentifier)
        isPlaying = fields[0] == "playing"
        title = fields[1].isEmpty ? "Music" : fields[1]
        artist = fields[2].isEmpty ? "Ready" : fields[2]
        album = fields[3]
        duration = Double(fields[4]) ?? 0
        elapsedTime = Double(fields[5]) ?? 0
        timestampDate = Date()
        playbackRate = isPlaying ? 1 : 0
        isShuffled = false
        repeatMode = fields[6].lowercased()
        lastArtworkURL = nil
        albumArt = icon(forBundleIdentifier: activeBundleIdentifier)
        return true
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Bundle IDs we've already asked macOS to authorize this session, so the 1s poll
    /// doesn't re-issue the request on every tick.
    private var automationRequested: Set<String> = []

    /// Explicitly requests Automation (Apple Events) permission to control `bundleID`.
    /// A bare `NSAppleScript` call can fail silently without ever surfacing the TCC
    /// prompt — especially on dev builds whose code signature changes each run — which
    /// is why the app may never appear under System Settings ▸ Privacy & Security ▸
    /// Automation. `AEDeterminePermissionToAutomateTarget` with askUserIfNeeded=true
    /// reliably triggers the system prompt the first time and registers the app there.
    /// Runs off the main thread because the call blocks while the dialog is up.
    private func requestAutomationPermission(forBundleIdentifier bundleID: String) {
        guard automationRequested.insert(bundleID).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = bundleID.data(using: .utf8) else { return }
            var target = AEAddressDesc()
            let createStatus = data.withUnsafeBytes { raw in
                AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &target)
            }
            guard createStatus == noErr else { return }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
            if status != noErr {
                print("⚠️ MackyMusicManager: Automation permission for \(bundleID) not granted (status \(status))")
            }
        }
    }

    private func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music")!
    }

    private func updateArtwork(from urlString: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
        // Avoid re-downloading the same artwork on every 1s poll.
        guard urlString != lastArtworkURL else { return }
        lastArtworkURL = urlString
        Task {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
            await MainActor.run {
                guard self.lastArtworkURL == urlString else { return }
                self.albumArt = image
            }
        }
    }

    private func runScript(command: String, in appName: String) {
        runScriptDetached("tell application \"\(appName)\" to \(command)")
    }

    /// Runs an AppleScript **off the main actor** and returns its string value.
    /// `NSAppleScript.executeAndReturnError` blocks the calling thread for the full
    /// Apple Event round-trip; running it on `@MainActor` (as the 1s poll used to)
    /// stalled the UI every tick. `nonisolated` + an off-main detached hop keeps the
    /// block off the main thread; callers `await` and then hop back to the main actor
    /// only to assign `@Published` state. Mirrors the detached-`Process` pattern in
    /// `SystemControlsIntegration.runAppleScript`.
    private nonisolated static func executeScript(_ source: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                // Don't swallow the failure: when this returns nil the panel falls back
                // to "Nothing playing" even while Spotify/Music is clearly playing. The
                // usual cause is the macOS Automation permission to control the player
                // being denied or never granted (error -1743 errAEEventNotPermitted),
                // fixable in System Settings ▸ Privacy & Security ▸ Automation ▸ Macky.
                let code = error[NSAppleScript.errorNumber] ?? "?"
                let message = error[NSAppleScript.errorMessage] ?? "unknown"
                print("⚠️ MackyMusicManager: AppleScript failed (\(code)): \(message)")
            }
            return result?.stringValue
        }.value
    }

    /// Read-path helper: runs `source` off the main actor and returns its string value.
    @discardableResult
    private func scriptValue(_ source: String) async -> String? {
        await Self.executeScript(source)
    }

    /// Fire-and-forget write-path helper for transport commands whose return value is
    /// unused. Runs off the main actor so a transport tap never blocks the UI.
    private func runScriptDetached(_ source: String) {
        Task { await Self.executeScript(source) }
    }

    /// Runs a script that returns tab-delimited fields. Returns nil if the script
    /// failed (e.g. Automation permission not granted) so the caller can fall back.
    private func scriptValues(_ source: String, expected: Int) async -> [String]? {
        guard let raw = await scriptValue(source) else { return nil }
        var fields = raw.components(separatedBy: "\t")
        guard fields.count >= expected else { return nil }
        if fields.count > expected {
            fields = Array(fields.prefix(expected))
        }
        return fields
    }
}

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
    @Published private(set) var selectedEvents: [CalEvent] = []
    @Published private(set) var reminders: [ReminderItem] = []

    private let store = EKEventStore()

    func refresh() async {
        await loadEvents(for: Date())
        await loadReminders()
    }

    func loadEvents(for date: Date) async {
        guard await ensureAccess(.event) else {
            todaysEvents = []
            selectedEvents = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        let events = store.events(matching: predicate)
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
        selectedEvents = events
        if calendar.isDateInToday(date) {
            todaysEvents = events
        }
    }

    private func loadReminders() async {
        guard await ensureAccess(.reminder) else {
            reminders = []
            return
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }
        reminders = fetched.prefix(8).map { ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "(untitled)") }
    }

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
                }
                return try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        case .writeOnly:
            return type == .reminder
        default:
            return false
        }
    }
}
