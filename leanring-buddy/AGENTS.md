# AGENTS.md — leanring-buddy (the Macky macOS app)

README and operating manual for the active macOS app target. Root `AGENTS.md` still
applies. A **User Instructions** section for humans is at the end.

> The folder, scheme, and project are named `leanring-buddy` (with the typo) for legacy
> reasons. This **is** the Macky app. Do not rename anything for branding.

---

## 1. What This Folder Is

A SwiftUI + AppKit **macOS accessory app** that renders a notch-first assistant UI,
captures push-to-talk audio, streams it to a realtime voice model through the Cloudflare
Worker, and exposes local macOS tools plus cloud tools (via Composio MCP). It runs as an
accessory (no Dock icon); all visible product UI lives in a borderless `NSPanel` aligned
to the notch.

---

## 2. Read First (for behavior / architecture work)

1. `../MACKY.md` — product brief and intended behavior.
2. `leanring_buddyApp.swift` — app entry point.
3. `CompanionManager.swift` — central state coordinator.
4. The specific file you plan to edit.
5. Direct callers/callees found with `rg`.

- **Notch / geometry work** — also read `NotchPanelController.swift`, `NotchUIModel.swift`,
  `NotchContainerView.swift`, `Notchshape.swift`, `AurenStatusBar.swift`, `AurenPanel.swift`,
  `AurenFileDropPanel.swift`, `WindowPositionManager.swift`.
- **Realtime / audio / tools** — also read `RealtimeClient.swift`,
  `BuddyDictationManager.swift`, `AudioConversionSupport.swift`, `VoiceActivityView.swift`,
  and the specific integration file involved.

---

## 3. File Map

### App lifecycle & state
- `leanring_buddyApp.swift` — sets accessory activation, registers the `Macky://auth` URL
  handler, creates and starts `CompanionManager`, and creates `NotchPanelController`.
- `CompanionManager.swift` — the central `@MainActor` state coordinator: permissions,
  shortcut state, voice state, operation state, pending attachments, pending connector
  (Composio Connect) links, and the history shown in the panel.

### Notch & panel UI
- `NotchPanelController.swift` — owns the borderless `NSPanel`, computes closed/open
  frames, and hosts SwiftUI without letting `NSHostingView` resize the window.
- `NotchUIModel.swift` — notch geometry and open/closed state **only** (no voice/tool
  state here).
- `NotchContainerView.swift`, `AurenStatusBar.swift`, `AurenPanel.swift`,
  `AurenFileDropPanel.swift`, `Notchshape.swift`, `VoiceActivityView.swift` — the notch UI
  and panel surfaces, the notch shape path, and the live voice waveform.
- `AuthView.swift`, `HotkeySettingsView.swift` — onboarding/auth and hotkey settings UI.
- `DesignSystem.swift` — shared design tokens and button styles.
- `AppKitExtensions.swift`, `WindowPositionManager.swift` — AppKit helpers and multi-display
  window placement.

### Voice pipeline
- `RealtimeClient.swift` — persistent WebSocket, `session.update` payload, realtime event
  parsing, local function-tool dispatch, Composio MCP registration, audio send/receive,
  heartbeat, and reconnect. Its Worker URLs (`workerRealtimeURL`, `composioConfigURL`)
  derive from the shared `WorkerEndpoints` — they are no longer hardcoded here.
- `WorkerEndpoints.swift` — the single source of truth for the hosted Worker's host
  (`baseHost`) and every derived URL (realtime socket, Composio config/connect/connections,
  auth base). Change `baseHost` here (only) to self-host the backend.
- `BuddyDictationManager.swift` — captures the mic and streams PCM16 24 kHz mono chunks.
- `AudioConversionSupport.swift` — audio format conversion helpers.
- `GlobalPushToTalkShortcutMonitor.swift` — listen-only global CGEvent tap for
  modifier-only push-to-talk.

### Auth
- `AuthManager.swift` — magic-link auth against the Worker; stores the session in
  Keychain. Its `workerBaseURL` derives from `WorkerEndpoints.httpsBase` (not hardcoded
  here). Handles the incoming `Macky://auth?token=…` deep link and exchanges the token via
  `/auth/verify`.

### Local integrations (macOS-native, no cloud)
- `CalendarIntegration.swift` — EventKit (calendar).
- `RemindersIntegration.swift` — EventKit (reminders).
- `SystemControlsIntegration.swift` — AppKit / AppleScript / CGEvent system shortcuts.
- `AppLauncherIntegration.swift` — `NSWorkspace` app launching.
- `CompanionScreenCaptureUtility.swift` — ScreenCaptureKit for on-demand screen context.
- `CursorControlIntegration.swift` — standalone CGEvent cursor movement, clicking, dragging,
  and scrolling. Visual guidance reuses it for pointing only.
- `VisualGuidance*` / `VisualScene*` — validated screenshot-coordinate diagrams, overlay
  rendering, optional Accessibility targets, and cursor labels.

### Observability
- `MackyAnalytics.swift` — thin wrapper over the PostHog SDK. No-ops until a
  `POSTHOG_API_KEY` (Info.plist or env) is configured, so dev builds ship nothing. Event
  **call sites** live in `CompanionManager` (turn latency, connector-connect funnel steps)
  and `RealtimeClient` (native + MCP tool success/failure, connect-link requested). Add new
  events through its `Event`/category methods, not a parallel API.
- `MackyCrashReporter.swift` — PLCrashReporter startup wiring, guarded by
  `#if canImport(CrashReporter)`. No-op until the `CrashReporter` package product is linked
  to the target in Xcode (it is resolved transitively but not yet a linked product).

### Config & resources
- `Info.plist` — bundle config, permission usage strings, the `Macky://` URL scheme.
- `leanring-buddy.entitlements` — sandbox/capabilities, permissions, URL scheme.
- `Assets.xcassets/` — app icon and colors.
- `enter.mp3`, `eshop.mp3` — UI sound effects.

---

## 4. Active Architecture Notes

- The realtime socket is **persistent**. The app connects once and stays connected; it
  does not connect/disconnect per utterance. On connect, the socket opens immediately and
  the one-time Composio MCP config is fetched **concurrently** (not before the socket) — if
  it resolves after the first `session.update`, the MCP tool is wired in with a follow-up
  update. A reconnect mid-utterance does **not** replay dropped mic audio (the server-side
  input buffer is cleared on reconnect, so replaying a fragment would mis-transcribe);
  instead the dropped utterance is surfaced via `lastError` rather than silently committed.
- macOS-native actions stay local in Swift; web services go through the **Composio MCP
  gateway** wired into the realtime session config — not through one-off OAuth clients.
- Screen context is **on demand** — the app does not capture or send screenshots on every
  key press, and by default captures only the cursor's display (the `get_screen_context`
  tool's `all_screens` flag opts into every monitor).
- Coordinate-based cursor actions require a fresh current-turn screen capture. Visual
  diagrams are generated on demand by GPT-5.6-sol through the authenticated Worker route;
  the realtime model remains responsible for deciding when to teach and for narration.
  Multi-display coordinate actions must use the capture's `display_id`, and any standalone
  cursor action invalidates cached coordinates before the next action.

---

## 5. Invariants (do not break)

- Keep `CompanionManager` and all UI-observed state on `@MainActor`.
- Keep the realtime socket persistent; preserve the heartbeat/reconnect lifecycle unless
  the task is specifically about connection reliability.
- Preserve **barge-in**: push-to-talk should interrupt current model playback before
  starting a new capture.
- The closed notch stays small and unobtrusive. Expansion happens only on hover, for
  onboarding/auth/settings, for file input, or for useful multi-step task output.
- Attach file/image context **before** `requestResponse()`.
- Web service integrations go through Composio MCP. Do not add one-off OAuth flows or
  direct API clients for Slack, Gmail, Spotify, GitHub, Notion, Linear, etc. unless
  explicitly asked.
- Do not rename `Auren*` files or symbols just for branding cleanup — some legacy names
  remain in active code.

---

## 6. Risky Files (state the exact reason before changing)

- `RealtimeClient.swift` — protocol, heartbeat, tool dispatch, MCP, audio playback.
- `CompanionManager.swift` — central state transitions.
- `GlobalPushToTalkShortcutMonitor.swift` — global event tap behavior; bugs here break the
  core interaction.
- `NotchPanelController.swift` / `NotchUIModel.swift` — geometry, animation, click-through
  surface.
- `DesignSystem.swift` — shared tokens and button styles.
- `Info.plist` / `leanring-buddy.entitlements` — permissions, URL scheme,
  sandbox/capabilities.

---

## 7. Validation

- Preferred verification is **Xcode on macOS**, not terminal `xcodebuild` (it can disturb
  TCC permissions).
- When you cannot build, limit validation to static checks: changed-file review, `rg` for
  callers/imports, and project membership for added files. State that no Xcode build ran.
- If you **add** a Swift file, confirm it is included in
  `../leanring-buddy.xcodeproj/project.pbxproj` (app target membership).
- If you **remove** a symbol, remove only the imports/code your change made unused. Do not
  delete pre-existing dead code opportunistically.

---

## User Instructions

For a human running the app.

1. Open `../leanring-buddy.xcodeproj` in Xcode, select the `leanring-buddy` scheme, and
   build & run (⌘R). Min target is macOS 14.2.
2. **Grant permissions** when prompted — Microphone, Accessibility (for the global
   push-to-talk tap), and Screen Recording (for screen context). Without Accessibility the
   hotkey will not fire; without Microphone there is no voice input.
3. **Sign in or skip for now** through the magic-link screen: enter your email, click the
   link that arrives by email (it opens the app via the `Macky://auth` URL scheme), and
   the session is saved to your Keychain. During early testing, you can also click
   **Skip for now** to continue onboarding without a saved session.
4. **Use it:** hold the push-to-talk shortcut (default modifier-only chord; configurable in
   the hotkey settings), speak, and release. Watch the notch for the listening waveform;
   the panel expands only when there is something to show.
5. **Connect cloud apps** (Slack, Gmail, Spotify, …) the first time the assistant needs
   them — it surfaces a Composio Connect link to authorize each service once.

> The backend Worker must be running/deployed for sign-in and realtime to work — see
> `../worker/AGENTS.md`.
