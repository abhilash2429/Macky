//
//  MackyAnalytics.swift
//  leanring-buddy
//
//  Minimal product-analytics surface for Macky. Wraps the PostHog SDK behind a
//  small, stable API so call sites in CompanionManager / RealtimeClient don't depend
//  on PostHog directly and so analytics is a no-op when unconfigured.
//
//  No-op by design when there is no API key: the key is read from the
//  `POSTHOG_API_KEY` Info.plist entry (which can be wired from a build setting /
//  xcconfig) or the same-named environment variable. Dev builds without a key never
//  initialize PostHog and every `capture` call returns immediately — so running the
//  app locally never ships events and never breaks.
//
//  Event vocabulary is intentionally small and centralized in `Event` /
//  property-key constants so the three milestone categories — turn latency, tool
//  success/failure (native + MCP), and the connector-connect funnel — stay
//  consistent and greppable.
//

import Foundation
import PostHog

@MainActor
enum MackyAnalytics {

    // MARK: - Event names (centralized so call sites can't drift)

    enum Event {
        /// Time from push-to-talk release to the first response-audio byte.
        static let turnLatency = "turn_latency"
        /// A native (local Swift) tool call finished — success or failure.
        static let nativeToolCall = "native_tool_call"
        /// An MCP (Composio) tool call finished — success or failure.
        static let mcpToolCall = "mcp_tool_call"
        /// Connector-connect funnel steps (see `ConnectStep`).
        static let connectorConnect = "connector_connect"
    }

    /// Steps in the connector-connect funnel, sent as the `step` property on
    /// `Event.connectorConnect`.
    enum ConnectStep: String {
        case linkRequested = "link_requested"
        case linkOpened = "link_opened"
        case connectionConfirmed = "connection_confirmed"
    }

    // MARK: - Lifecycle

    private static var isConfigured = false

    /// The PostHog project API key, or nil when unconfigured (→ analytics no-ops).
    /// Read from Info.plist `POSTHOG_API_KEY` first, then the environment, so a key
    /// can be injected via an xcconfig/build setting without code changes and dev
    /// builds with no key stay silent.
    private static var apiKey: String? {
        if let key = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String,
           !key.isEmpty, key != "$(POSTHOG_API_KEY)" {
            return key
        }
        if let key = ProcessInfo.processInfo.environment["POSTHOG_API_KEY"], !key.isEmpty {
            return key
        }
        return nil
    }

    private static var host: String {
        (Bundle.main.object(forInfoDictionaryKey: "POSTHOG_HOST") as? String).flatMap {
            $0.isEmpty || $0 == "$(POSTHOG_HOST)" ? nil : $0
        } ?? "https://us.i.posthog.com"
    }

    /// Initializes PostHog once, at app startup. A no-op (and leaves analytics
    /// disabled) when no API key is configured, so local/dev builds ship nothing.
    static func start() {
        guard !isConfigured, let apiKey else {
            if apiKey == nil { print("ℹ️ MackyAnalytics: no POSTHOG_API_KEY — analytics disabled") }
            return
        }
        let config = PostHogConfig(apiKey: apiKey, host: host)
        PostHogSDK.shared.setup(config)
        isConfigured = true
        print("📈 MackyAnalytics: PostHog configured")
    }

    // MARK: - Capture

    /// Low-level capture. No-op until `start()` has configured PostHog with a key.
    static func capture(_ event: String, _ properties: [String: Any]? = nil) {
        guard isConfigured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    // MARK: - The three milestone event categories

    /// Turn latency: push-to-talk release → first response-audio byte, in milliseconds.
    static func turnLatency(milliseconds: Int) {
        capture(Event.turnLatency, ["latency_ms": milliseconds])
    }

    /// A native or MCP tool call finished. `success` distinguishes the
    /// `{"error": …}` path from a real result.
    static func toolCall(name: String, isMCP: Bool, success: Bool) {
        capture(isMCP ? Event.mcpToolCall : Event.nativeToolCall, [
            "tool": name,
            "success": success
        ])
    }

    /// A step in the connector-connect funnel for a given toolkit.
    static func connectorConnect(step: ConnectStep, toolkit: String) {
        capture(Event.connectorConnect, [
            "step": step.rawValue,
            "toolkit": toolkit
        ])
    }
}
