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
                LazyVStack(spacing: 8) {
                    ForEach(filteredConnectors) { connector in
                        ConnectorListRow(
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            TextField("Search 250+ connectors…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill))
        )
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
            accent: Color.accentColor,
            badge: .popular(2),
            examples: ["Write a follow-up to John", "Find the latest client email", "Summarize unread mail"]
        ),
        ConnectorCardMeta(
            slug: "slack",
            icon: "number",
            category: "Communication",
            description: "Send messages, look up channels, and turn threads into next actions.",
            accent: Color.accentColor,
            badge: .popular(9),
            examples: ["Send the standup update", "Catch me up on design", "Post a reminder"]
        ),
        ConnectorCardMeta(
            slug: "googlecalendar",
            icon: "calendar",
            category: "Planning",
            description: "Create meetings and inspect availability through Composio.",
            accent: Color.accentColor,
            badge: .popular(3),
            examples: ["Schedule a call tomorrow", "Move my 3 PM meeting", "Find open time Friday"]
        ),
        ConnectorCardMeta(
            slug: "notion",
            icon: "doc.text.fill",
            category: "Knowledge",
            description: "Create pages, update notes, and pull workspace context into Macky.",
            accent: Color.accentColor,
            badge: .popular(6),
            examples: ["Add this to product notes", "Find the launch checklist", "Create a meeting page"]
        ),
        ConnectorCardMeta(
            slug: "github",
            icon: "chevron.left.forwardslash.chevron.right",
            category: "Developer",
            description: "Read issues, create pull requests, and work with repositories.",
            accent: Color.accentColor,
            badge: .new,
            examples: ["Open a bug issue", "Summarize recent PRs", "Find failing checks"]
        ),
        ConnectorCardMeta(
            slug: "linear",
            icon: "line.3.horizontal.decrease.circle.fill",
            category: "Planning",
            description: "Create issues, inspect cycles, and keep project status moving.",
            accent: Color.accentColor,
            badge: .new,
            examples: ["Create a task for this", "Move it to in progress", "List urgent bugs"]
        ),
        ConnectorCardMeta(
            slug: "spotify",
            icon: "music.note",
            category: "Media",
            description: "Control playback and use music context without leaving the notch.",
            accent: Color.accentColor,
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

private struct ConnectorListRow: View {
    let connector: MackyConnector
    let pendingConnection: PendingConnection?
    let isConnected: Bool
    let onConnect: () -> Void
    let onOpenPending: (PendingConnection) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ConnectorIcon(connector: connector, size: 38, iconSize: 17)

            VStack(alignment: .leading, spacing: 3) {
                Text(connector.name)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Text(connector.description)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            actionControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// Trailing action control: a live connection shows a static "Connected"
    /// pill (no action), a pending link resumes that authorization flow, and
    /// otherwise a "Connect" pill kicks off a new one.
    @ViewBuilder
    private var actionControl: some View {
        if isConnected {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Connected")
                    .font(.system(.footnote, design: .rounded))
                    .fontWeight(.semibold)
            }
            .foregroundColor(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.green.opacity(0.16)))
            .help("\(connector.name) is connected")
        } else if let pendingConnection {
            Button {
                onOpenPending(pendingConnection)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Resume")
                        .font(.system(.footnote, design: .rounded))
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help("Open authorization link")
        } else {
            Button(action: onConnect) {
                Text("Connect")
                    .font(.system(.footnote, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help("Connect \(connector.name)")
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
        let corner = min(11, size * 0.28)
        Group {
            if let logoImage {
                Image(nsImage: logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.18)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color(nsColor: .secondarySystemFill))
                    )
            } else {
                // Fallback: the brand mark/letter on the same system-adaptive tile.
                Image(systemName: connector.icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color(nsColor: .secondarySystemFill))
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct SettingsPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var authManager = AuthManager.shared

    /// A live, accurate summary of connected connectors — never a hardcoded 0.
    /// Reads the real set of connected toolkits from the worker (populated by
    /// `refreshConnectedToolkits`), so Settings reflects what's actually wired up.
    private var connectorsSummary: String {
        let count = companionManager.connectedToolkits.count
        return count == 1 ? "1 connected" : "\(count) connected"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                generalSection
                contextSection
                permissionsSection
                shortcutsSection
                accountSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .onAppear { companionManager.refreshConnectedToolkits() }
    }

    private var generalSection: some View {
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
    }

    private var permissionsSection: some View {
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
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelTitle("App Context", subtitle: "Make voice requests less repetitive in the app you are using.")
            Toggle(isOn: Binding(
                get: { companionManager.isForegroundAppContextEnabled },
                set: { companionManager.setForegroundAppContextEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use current app while speaking")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.white.opacity(0.9))
                    Text("Sends only the active app name and bundle ID with each voice request. Macky never reads window titles, text, web pages, or app activity in the background.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .secondarySystemFill)))
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelTitle("Shortcuts", subtitle: "Push-to-talk listens globally while Macky is running.")
            HotkeySettingsView(companionManager: companionManager)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
        }
    }

    private var accountSection: some View {
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
            .font(.system(.footnote, design: .rounded))
            .fontWeight(.semibold)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 16)
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .secondarySystemFill)))
    }
}

private extension View {
    func mackySettingsButton() -> some View {
        self
            .buttonStyle(.plain)
            .font(.system(size: DS.Typography.panelAction, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: granted ? .medium : .light))
                .foregroundStyle(granted ? Color.green : Color.white.opacity(0.4))
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(.footnote, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            } else {
                Button("Allow") { action() }
                    .buttonStyle(.plain)
                    .font(.system(.footnote, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .secondarySystemFill)))
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
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
            Text(subtitle)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.4))
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

