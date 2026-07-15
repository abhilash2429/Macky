//
//  ConnectorRegistry.swift
//  leanring-buddy
//
//  Maps a Composio MCP tool name to the connector (toolkit) it belongs to, so the
//  notch's branding chrome can show that connector's logo while its tool call runs.
//
//  This file is the single client-side source of truth for connector identity: it pairs
//  a toolkit slug with a display name and a bundled logo asset. Both the notch's
//  logo-swap (via `match(toolName:)`) and the connectors grid in AurenPanel.swift read
//  from this same list, so the two can't drift (they previously did — the grid listed 7
//  toolkits while this table had only 4, so a Notion/GitHub/Linear call never swapped the
//  notch logo). The grid layers UI-only metadata (icon, category, blurb, examples) on top
//  of these identities. The status text shown during a call is never hardcoded here — it
//  stays the model's own narration. A toolkit absent from this table (or
//  COMPOSIO_MANAGE_CONNECTIONS, which belongs to no toolkit) simply doesn't match, so the
//  branding icon stays put.
//

import Foundation

/// The identity of a Composio connector (toolkit) for branding purposes.
struct ConnectorIdentity: Equatable {
    /// Composio toolkit slug, e.g. "gmail". Also the matching key.
    let slug: String
    /// Human-facing name, e.g. "Gmail".
    let displayName: String
    /// Asset-catalog image name. Follows the existing `ConnectorLogo-<slug>` convention
    /// shared with the connectors grid (see `ConnectorIcon` in AurenPanel.swift), so the
    /// logo assets are reused rather than duplicated.
    let logoAssetName: String
}

enum ConnectorRegistry {
    /// The registered connector set — the single client-side list of (slug, display name,
    /// logo asset) shared by the notch logo-swap and the connectors grid. Each entry must
    /// have a bundled `ConnectorLogo-<slug>` asset; the icon swap is gated on the asset
    /// resolving at render time, so an entry without an asset falls back to the default
    /// branding icon rather than a broken image. Keep this list in sync with the available
    /// `ConnectorLogo-<slug>` assets; the grid derives its slug/name/logo from here.
    static let connectors: [ConnectorIdentity] = [
        ConnectorIdentity(slug: "gmail", displayName: "Gmail", logoAssetName: "ConnectorLogo-gmail"),
        ConnectorIdentity(slug: "slack", displayName: "Slack", logoAssetName: "ConnectorLogo-slack"),
        ConnectorIdentity(slug: "googlecalendar", displayName: "Google Calendar", logoAssetName: "ConnectorLogo-googlecalendar"),
        ConnectorIdentity(slug: "notion", displayName: "Notion", logoAssetName: "ConnectorLogo-notion"),
        ConnectorIdentity(slug: "github", displayName: "GitHub", logoAssetName: "ConnectorLogo-github"),
        ConnectorIdentity(slug: "linear", displayName: "Linear", logoAssetName: "ConnectorLogo-linear"),
        ConnectorIdentity(slug: "spotify", displayName: "Spotify", logoAssetName: "ConnectorLogo-spotify"),
    ]

    /// Looks up a connector identity by its toolkit slug (the single shared key). Used by
    /// the connectors grid so its slug/display name/logo come from this same source.
    static func identity(forSlug slug: String) -> ConnectorIdentity? {
        connectors.first { $0.slug == slug.lowercased() }
    }

    /// Resolves an MCP tool name to its connector, or nil if none is registered.
    ///
    /// Composio tool names are UPPER_SNAKE and prefixed with the toolkit slug, e.g.
    /// `GMAIL_SEND_EMAIL`, `GOOGLECALENDAR_CREATE_EVENT`, `SLACK_SENDS_MESSAGE`. We match
    /// on the leading underscore-delimited token so only the toolkit prefix decides the
    /// connector. `COMPOSIO_MANAGE_CONNECTIONS` → token "composio" → no match (correct:
    /// it's the meta tool, not a user-facing connector). Native Swift tools never reach
    /// this path — they dispatch through `onToolCallStarted`, not the MCP callbacks.
    static func match(toolName: String) -> ConnectorIdentity? {
        let leadingToken = toolName
            .lowercased()
            .split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? toolName.lowercased()
        return connectors.first { $0.slug == leadingToken }
    }
}
