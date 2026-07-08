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
            VStack(alignment: .leading, spacing: 11) {
                if companionManager.isAssistantActive {
                    AssistantActivityCard(companionManager: companionManager)
                }

                HStack(alignment: .top, spacing: 11) {
                    // LEFT — music on top, recent activity (history) below it.
                    VStack(alignment: .leading, spacing: 11) {
                        BoringStyleMusicCard(music: music)

                        if !companionManager.recentInteractions.isEmpty {
                            PanelSection("Recent Activity") {
                                ForEach(companionManager.recentInteractions.prefix(3)) { interaction in
                                    ActivityRow(interaction: interaction)
                                }
                            }
                        }
                    }
                    .frame(width: 300)

                    // RIGHT — calendar and reminders.
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(width: 26, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.Colors.surface3))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                VoiceActivityView(companionManager: companionManager, realtimeClient: companionManager.realtimeClient)
                    .frame(width: 26, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(DS.Gradients.panelSubtle)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(companionManager.activeStatusText.isEmpty ? "Ready" : companionManager.activeStatusText)
                    .font(.system(size: DS.PanelTypography.size(11), weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Macky is working in the notch.")
                    .font(.system(size: DS.PanelTypography.size(9)))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

private struct BoringStyleMusicCard: View {
    @ObservedObject var music: MackyMusicManager
    @State private var isDragging = false
    @State private var sliderValue: Double = 0

    var body: some View {
        HStack(spacing: 11) {
            albumArt
                .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 8) {
                songInfo
                TimelineView(.animation(minimumInterval: music.isPlaying ? 0.5 : nil)) { _ in
                    progressSlider
                }
                controlToolbar

                Button {
                    music.openActiveMusicApp()
                } label: {
                    Label(music.activeAppName, systemImage: "arrow.up.forward.app")
                        .font(.system(size: DS.PanelTypography.size(8), weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        // Same flat surface as the Calendar/Reminders cards so the home page reads
        // as one cohesive panel instead of a distinct, album-tinted left container.
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
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
                .frame(width: 18, height: 18)
                .padding(4)
                .background(Circle().fill(Color.black.opacity(0.78)))
                .offset(x: 6, y: 6)
        }
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.title)
                .font(.system(size: DS.PanelTypography.size(13), weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(music.artist)
                .font(.system(size: DS.PanelTypography.size(11), weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
            Text(music.album)
                .font(.system(size: DS.PanelTypography.size(9)))
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
            .font(.system(size: DS.PanelTypography.size(8), weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
        }
    }

    private var controlToolbar: some View {
        HStack(spacing: 6) {
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
                .font(.system(size: DS.PanelTypography.size(isPrimary ? 12 : 10), weight: .semibold))
                .foregroundStyle(isPrimary ? DS.Colors.textOnAccent : (isActive ? DS.Colors.textPrimary : .white))
                .frame(width: isPrimary ? 26 : 20, height: isPrimary ? 26 : 20)
                .background(Circle().fill(isPrimary ? DS.Colors.accent : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct CalendarCard: View {
    @ObservedObject var sidebar: AurenSidebarData
    @State private var selectedDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Full month + year, matching the screenshot's "July 2026" heading.
            Text("\(selectedDate.formatted(.dateTime.month(.wide))) \(selectedDate.formatted(.dateTime.year()))")
                .font(.system(size: DS.PanelTypography.size(15), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            MackyWeekStrip(selectedDate: $selectedDate)
                .frame(maxWidth: .infinity, alignment: .leading)

            if sidebar.selectedEvents.isEmpty {
                EmptyPanelLine(
                    icon: "calendar.badge.checkmark",
                    title: Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events"
                )
            } else {
                ForEach(Array(sidebar.selectedEvents.prefix(3).enumerated()), id: \.element.id) { index, event in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(index == 0 ? DS.Colors.accentText : DS.Colors.floatingGradientPurple)
                            .frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: DS.PanelTypography.size(11), weight: .semibold))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(event.timeString)
                                .font(.system(size: DS.PanelTypography.size(9)))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .task { await sidebar.loadEvents(for: selectedDate) }
        .onChange(of: selectedDate) { _, newDate in
            Task { await sidebar.loadEvents(for: newDate) }
        }
    }
}

/// A clean week strip — weekday initial over the day number, six days across,
/// today highlighted in a soft rounded tile. Matches the calendar header in the
/// panel screenshots (e.g. "W T F S S M / 1 2 3 4 5 6" with today filled).
private struct MackyWeekStrip: View {
    @Binding var selectedDate: Date

    /// Six consecutive days starting today, so the current day leads the strip.
    private let days: [Date] = {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return (0..<6).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)
                Button {
                    withAnimation(.smooth(duration: 0.18)) { selectedDate = day }
                } label: {
                    VStack(spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: DS.PanelTypography.size(9), weight: .medium))
                            .foregroundStyle(DS.Colors.textTertiary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: DS.PanelTypography.size(13), weight: .semibold))
                            .foregroundStyle(isSelected ? .white : DS.Colors.textPrimary.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { selectedDate = Date() }
    }
}

private struct RemindersCard: View {
    @ObservedObject var sidebar: AurenSidebarData

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Reminders")
                .font(.system(size: DS.PanelTypography.size(10), weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(1.2)

            if sidebar.reminders.isEmpty {
                EmptyPanelLine(icon: "checklist", title: "No open reminders")
            } else {
                ForEach(sidebar.reminders.prefix(4)) { reminder in
                    Button {
                        withAnimation(.smooth(duration: 0.16)) {
                            sidebar.complete(reminder)
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "circle")
                                .font(.system(size: DS.PanelTypography.size(12), weight: .light))
                                .foregroundStyle(DS.Colors.textTertiary)
                            Text(reminder.title)
                                .font(.system(size: DS.PanelTypography.size(11), weight: .medium))
                                .foregroundStyle(DS.Colors.textPrimary.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

private struct EmptyPanelLine: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: DS.PanelTypography.size(10)))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: DS.PanelTypography.size(9)))
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
        }
        .frame(height: 22)
    }
}

private struct ConnectorsPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9)
    ]

    private var filteredConnectors: [MackyConnector] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return MackyConnectorCatalog.items }
        return MackyConnectorCatalog.items.filter {
            $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            searchBar

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 9) {
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
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .onAppear { companionManager.refreshConnectedToolkits() }
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
            TextField("Search 250+ connectors…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: DS.PanelTypography.size(12)))
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
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
            accent: DS.Colors.accentText,
            badge: .popular(2),
            examples: ["Write a follow-up to John", "Find the latest client email", "Summarize unread mail"]
        ),
        ConnectorCardMeta(
            slug: "slack",
            icon: "number",
            category: "Communication",
            description: "Send messages, look up channels, and turn threads into next actions.",
            accent: DS.Colors.accentText,
            badge: .popular(9),
            examples: ["Send the standup update", "Catch me up on design", "Post a reminder"]
        ),
        ConnectorCardMeta(
            slug: "googlecalendar",
            icon: "calendar",
            category: "Planning",
            description: "Create meetings and inspect availability through Composio.",
            accent: DS.Colors.accentText,
            badge: .popular(3),
            examples: ["Schedule a call tomorrow", "Move my 3 PM meeting", "Find open time Friday"]
        ),
        ConnectorCardMeta(
            slug: "notion",
            icon: "doc.text.fill",
            category: "Knowledge",
            description: "Create pages, update notes, and pull workspace context into Macky.",
            accent: DS.Colors.accentText,
            badge: .popular(6),
            examples: ["Add this to product notes", "Find the launch checklist", "Create a meeting page"]
        ),
        ConnectorCardMeta(
            slug: "github",
            icon: "chevron.left.forwardslash.chevron.right",
            category: "Developer",
            description: "Read issues, create pull requests, and work with repositories.",
            accent: DS.Colors.accentText,
            badge: .new,
            examples: ["Open a bug issue", "Summarize recent PRs", "Find failing checks"]
        ),
        ConnectorCardMeta(
            slug: "linear",
            icon: "line.3.horizontal.decrease.circle.fill",
            category: "Planning",
            description: "Create issues, inspect cycles, and keep project status moving.",
            accent: DS.Colors.accentText,
            badge: .new,
            examples: ["Create a task for this", "Move it to in progress", "List urgent bugs"]
        ),
        ConnectorCardMeta(
            slug: "spotify",
            icon: "music.note",
            category: "Media",
            description: "Control playback and use music context without leaving the notch.",
            accent: DS.Colors.accentText,
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConnectorIcon(connector: connector, size: 40, iconSize: 18)

                VStack(alignment: .leading, spacing: 5) {
                    Text(connector.name)
                        .font(.system(size: DS.PanelTypography.size(13), weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    statusBadge
                }
                .padding(.top, 2)

                Spacer(minLength: 0)

                actionButton
            }

            Text(connector.description)
                .font(.system(size: DS.PanelTypography.size(11)))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    /// Connection-status pill under the connector name: "Connected" in a success
    /// tone when the toolkit is live, "Connect" in an accent tone otherwise.
    @ViewBuilder
    private var statusBadge: some View {
        if isConnected {
            Badge(text: "Connected", tone: .success)
        } else {
            Badge(text: "Connect", tone: .accent)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isConnected {
            // Live, end-to-end connection: show a tick, no action needed.
            Image(systemName: "checkmark")
                .font(.system(size: DS.PanelTypography.size(12), weight: .semibold))
                .foregroundStyle(DS.Colors.success)
                .frame(width: 30, height: 30)
                .background(Circle().fill(DS.Colors.success.opacity(0.16)))
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
                    .font(.system(size: DS.PanelTypography.size(12), weight: .semibold))
                    .foregroundStyle(DS.Colors.textOnAccent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pendingConnection != nil ? "Open authorization link" : "Connect \(connector.name)")
        }
    }
}

/// A small status pill used on connector cards. `success` reads as a live
/// connection, `accent` as an available-to-connect action.
private struct Badge: View {
    enum Tone { case success, accent }
    let text: String
    let tone: Tone

    private var foreground: Color {
        tone == .success ? DS.Colors.success : DS.Colors.accentText
    }
    private var fill: Color {
        tone == .success ? DS.Colors.success.opacity(0.16) : DS.Colors.accent.opacity(0.16)
    }

    var body: some View {
        Text(text)
            .font(.system(size: DS.PanelTypography.size(10), weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
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
        let corner = min(11, size * 0.28)
        Group {
            if let logoImage {
                // Official logo on a near-black tile so connector rows stay inside
                // the panel's flat black palette.
                Image(nsImage: logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.18)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(DS.Colors.surface3)
                    )
            } else {
                // Fallback: the brand mark/letter on the same near-black tile.
                Image(systemName: connector.icon)
                    .font(.system(size: DS.PanelTypography.size(iconSize), weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(DS.Colors.surface3)
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
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .shortcuts: return "keyboard"
            case .account: return "person.crop.circle"
            }
        }
    }

    /// A live, accurate summary of connected connectors — never a hardcoded 0.
    /// Reads the real set of connected toolkits from the worker (populated by
    /// `refreshConnectedToolkits`), so Settings reflects what's actually wired up.
    private var connectorsSummary: String {
        let count = companionManager.connectedToolkits.count
        return count == 1 ? "1 connected" : "\(count) connected"
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                MackyGlyphLogo(size: 26, glow: false)
                    .padding(.leading, 6)
                    .padding(.bottom, 12)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: DS.PanelTypography.size(11), weight: .medium))
                                .frame(width: 14)
                            Text(tab.rawValue)
                                .font(.system(size: DS.PanelTypography.size(11), weight: isSelected ? .semibold : .medium))
                            Spacer()
                        }
                        .foregroundStyle(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 132, alignment: .topLeading)
            .padding(.top, 8)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            ScrollView(.vertical, showsIndicators: false) {
                settingsDetail
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 18)
        .onAppear { companionManager.refreshConnectedToolkits() }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedTab {
        case .general:
            VStack(alignment: .leading, spacing: 9) {
                PanelTitle("General", subtitle: "Panel, status, and active-state controls.")
                SettingsInfoRow(icon: "capsule.portrait.fill", title: "Notch UI", value: "Enabled")
                SettingsInfoRow(icon: "waveform", title: "Active state", value: companionManager.activeStatusText.isEmpty ? "Idle" : companionManager.activeStatusText)
                SettingsInfoRow(
                    icon: "square.grid.2x2",
                    title: "Connectors",
                    value: connectorsSummary
                )
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 9) {
                PanelTitle("Permissions", subtitle: "Grant access without leaving the panel flow.")
                SettingsPermissionRow(title: "Microphone", granted: companionManager.hasMicrophonePermission) {
                    companionManager.requestMicrophonePermission()
                }
                SettingsPermissionRow(title: "Accessibility", granted: companionManager.hasAccessibilityPermission) {
                    companionManager.requestAccessibilityPermission()
                }
                SettingsPermissionRow(title: "Automation (AppleScript)", granted: companionManager.hasAutomationPermission) {
                    companionManager.requestAutomationPermission()
                }
                SettingsPermissionRow(title: "Calendar", granted: companionManager.hasCalendarPermission) {
                    companionManager.requestCalendarPermission()
                }
                SettingsPermissionRow(title: "Reminders", granted: companionManager.hasRemindersPermission) {
                    companionManager.requestRemindersPermission()
                }
                SettingsPermissionRow(title: "Screen Recording", granted: companionManager.hasScreenRecordingPermission) {
                    companionManager.requestScreenRecordingPermission()
                }
                SettingsPermissionRow(title: "Screen Content", granted: companionManager.hasScreenContentPermission) {
                    companionManager.requestScreenContentPermission()
                }
            }
        case .shortcuts:
            VStack(alignment: .leading, spacing: 9) {
                PanelTitle("Shortcuts", subtitle: "Push-to-talk listens globally while Macky is running.")
                HotkeySettingsView(companionManager: companionManager)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
        case .account:
            VStack(alignment: .leading, spacing: 9) {
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
                .font(.system(size: DS.PanelTypography.size(11), weight: .semibold))
                .foregroundStyle(DS.Colors.destructiveText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.destructive))
            }
        }
    }
}

private struct SettingsInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 16)
            Text(title)
                .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            Spacer()
            Text(value)
                .font(.system(size: DS.PanelTypography.size(10), weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

private extension View {
    func mackySettingsButton() -> some View {
        self
            .buttonStyle(.plain)
            .font(.system(size: DS.PanelTypography.size(11), weight: .semibold))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: DS.PanelTypography.size(15), weight: granted ? .medium : .light))
                .foregroundStyle(granted ? DS.Colors.success : DS.Colors.textTertiary)
            Text(title)
                .font(.system(size: DS.PanelTypography.size(12), weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: DS.PanelTypography.size(10), weight: .semibold))
                    .foregroundStyle(DS.Colors.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.success.opacity(0.15)))
            } else {
                Button("Allow") { action() }
                    .buttonStyle(.plain)
                    .font(.system(size: DS.PanelTypography.size(10), weight: .semibold))
                    .foregroundStyle(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.accent))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
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
                .font(.system(size: DS.PanelTypography.size(19), weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: DS.PanelTypography.size(11)))
                .foregroundStyle(DS.Colors.textTertiary)
        }
        .padding(.bottom, 4)
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
                .font(.system(size: DS.PanelTypography.size(10), weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(1.2)
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
                .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button("Open link", action: onConnect)
                .buttonStyle(.plain)
                .font(.system(size: DS.PanelTypography.size(11), weight: .semibold))
                .foregroundStyle(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.accent))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: DS.PanelTypography.size(9), weight: .bold))
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: DS.PanelTypography.size(11), weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(timeString)
                        .font(.system(size: DS.PanelTypography.size(10)))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                if isExpanded, let detail {
                    Text(detail)
                        .font(.system(size: DS.PanelTypography.size(10)))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
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
                return CalEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(untitled)",
                    timeString: event.isAllDay ? "All day" : timeFormatter.string(from: event.startDate),
                    color: DS.Colors.accentText
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
