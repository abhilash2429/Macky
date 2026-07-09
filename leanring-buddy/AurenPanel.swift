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
import SwiftUI

enum MackyPanelPage {
    case home
    case connectors
    case settings
}

struct AurenPanel: View {
    @ObservedObject var companionManager: CompanionManager
    let page: MackyPanelPage
    var onOpenConnectors: () -> Void = {}

    var body: some View {
        switch page {
        case .home:
            home
        case .connectors:
            ConnectorsPanel(companionManager: companionManager)
        case .settings:
            SettingsPanel(companionManager: companionManager)
        }
    }

    private var home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                IconPreviewStrip(
                    title: "Skills",
                    statusText: enabledSkills.isEmpty ? nil : "\(enabledSkills.count) active",
                    icons: enabledSkills.map { .init(id: $0.id, systemName: $0.icon, image: nil) },
                    onTap: { SkillsWindowController.shared.showWindow() }
                )

                IconPreviewStrip(
                    title: "Connectors",
                    statusText: nil,
                    icons: connectedConnectors.map { .init(id: $0.slug, systemName: nil, image: NSImage(named: $0.logoAssetName)) },
                    onTap: onOpenConnectors
                )

                ChatsSection(interactions: companionManager.recentInteractions)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .onAppear { companionManager.refreshConnectedToolkits() }
    }

    private var enabledSkills: [SkillIdentity] {
        SkillRegistry.skills.filter { companionManager.isSkillEnabled($0.id) }
    }

    private var connectedConnectors: [ConnectorIdentity] {
        ConnectorRegistry.connectors.filter { companionManager.connectedToolkits.contains($0.slug) }
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

/// Home page's chats section: a horizontal strip of recent interactions (mirroring
/// components/Shelf/Views/ShelfView.swift's ScrollView(.horizontal) { HStack { ForEach } }
/// layout, without its drag/drop/selection machinery), or the detail of one tapped
/// interaction. Renders `interactions` in the order CompanionManager provides it —
/// no sorting or truncating here.
private struct ChatsSection: View {
    let interactions: [Interaction]
    @State private var selectedInteraction: Interaction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedInteraction {
                ChatDetailView(interaction: selectedInteraction) {
                    self.selectedInteraction = nil
                }
            } else {
                Text("Chats")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))

                if interactions.isEmpty {
                    Text("No recent chats yet")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(interactions) { interaction in
                                ChatChip(interaction: interaction) {
                                    selectedInteraction = interaction
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A single chat's preview tile on the Home chats strip. Uses the same tile
/// vocabulary as IconPreviewStrip's IconTile (30x30, 8pt corner radius,
/// `.secondarySystemFill`) for visual consistency, plus a short truncated label
/// so chips remain distinguishable from one another at a glance.
private struct ChatChip: View {
    let interaction: Interaction
    let onTap: () -> Void

    private var label: String {
        let phrase = interaction.userPhrase.isEmpty ? interaction.modelSummary : interaction.userPhrase
        return phrase.isEmpty ? "Chat" : phrase
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                Text(label)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 56)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Full detail for one tapped chat: a back button to return to the strip, then the
/// user's phrase and the model's summary, each clearly labeled, plus a
/// human-readable timestamp.
private struct ChatDetailView: View {
    let interaction: Interaction
    let onBack: () -> Void

    private var formattedTimestamp: String {
        interaction.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)

                Text("Chat")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                Text(formattedTimestamp)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("You said")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.accentColor)
                Text(interaction.userPhrase.isEmpty ? "—" : interaction.userPhrase)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .secondarySystemFill)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Macky replied")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.accentColor)
                Text(interaction.modelSummary.isEmpty ? "—" : interaction.modelSummary)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .secondarySystemFill)))
        }
    }
}

