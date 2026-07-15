import Foundation

/// The single source of truth for the hosted Cloudflare Worker's location.
///
/// The app targets a hosted Worker by default; its host used to be hardcoded
/// independently in five places across three files (`AuthManager`, `RealtimeClient`,
/// `CompanionManager`), so a self-hoster who changed only the ones the docs named ended
/// up with a split configuration where connector calls still hit the original Worker.
///
/// **Self-hosting:** deploy `worker/` and change `baseHost` below — that is the *only*
/// place the Worker host is defined in the Swift app now. Everything else derives from it.
enum WorkerEndpoints {
    /// The Worker host (no scheme, no trailing slash). The single value to change when
    /// self-hosting the backend.
    static let baseHost = "realtime-proxy.speedmac.workers.dev"

    /// `https://<host>` — base for the REST routes (auth + Composio connect/connections/config).
    static let httpsBase = "https://\(baseHost)"

    /// WebSocket URL for the realtime audio proxy (`/realtime`).
    static let realtimeURL = URL(string: "wss://\(baseHost)/realtime")!

    /// One-time Composio MCP session config fetch (`/composio-config`) → `{ url, key }`.
    /// Requires an `Authorization: Bearer <sessionToken>` header (see `AuthManager`).
    static let composioConfigURL = URL(string: "\(httpsBase)/composio-config")!

    /// Composio OAuth redirect-URL fetch for a single toolkit (`/composio-connect`).
    static let composioConnectURL = URL(string: "\(httpsBase)/composio-connect")!

    /// List of the user's active toolkit connections (`/composio-connections`).
    static let composioConnectionsURL = URL(string: "\(httpsBase)/composio-connections")!

    /// Fast, direct "play a Spotify track by name" route (`/spotify-play`). Does the
    /// search→play chain server-side in one hop, bypassing the slow MCP tool-router
    /// discovery the model would otherwise drive across several round-trips.
    static let spotifyPlayURL = URL(string: "\(httpsBase)/spotify-play")!

    /// Isolated text-only gpt-realtime-2.1-mini session for Ctrl + Fn
    /// dictation. It is separate from the persistent assistant socket and is
    /// created only after the local focused-field safety check.
    static let dictationRealtimeURL = URL(string: "wss://\(baseHost)/dictation/realtime")!

}
