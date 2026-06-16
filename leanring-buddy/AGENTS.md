# AGENTS.md - leanring-buddy

Scope: active macOS app target only. Root instructions still apply.

## What This Folder Contains

This is the Speed app even though the folder and scheme still say `leanring-buddy`. It is a SwiftUI/AppKit macOS accessory app that renders a notch-first assistant UI, captures push-to-talk audio, streams it to a realtime model through the Worker, and exposes local macOS tools.

## Read First

For behavior or architecture work, read in this order:

1. `../SPEED.md`
2. `leanring_buddyApp.swift`
3. `CompanionManager.swift`
4. The specific file you plan to edit
5. Direct callers/callees found with `rg`

For visual or notch geometry work, also read `NotchPanelController.swift`, `NotchUIModel.swift`, `NotchContainerView.swift`, `AurenStatusBar.swift`, and `AurenPanel.swift`.

For realtime/audio/tool work, also read `RealtimeClient.swift`, `BuddyDictationManager.swift`, `AudioConversionSupport.swift`, and the integration file involved.

## Active Architecture

- `leanring_buddyApp.swift` sets accessory activation, registers the `Speed://auth` URL handler, creates `CompanionManager`, starts it, and creates `NotchPanelController`.
- `NotchPanelController.swift` owns the borderless `NSPanel`, computes closed/open frames, and hosts SwiftUI without letting `NSHostingView` resize the window.
- `NotchUIModel.swift` owns notch geometry and open/closed state only. Do not put voice or tool state here.
- `NotchContainerView.swift`, `AurenStatusBar.swift`, `AurenPanel.swift`, `AurenFileDropPanel.swift`, and `AuthView.swift` make up the notch UI and panel surfaces.
- `CompanionManager.swift` is the central state coordinator for permissions, shortcut state, voice state, operation state, pending attachments, pending connector links, and history.
- `RealtimeClient.swift` owns the persistent WebSocket, session update payload, realtime event parsing, local function tools, Composio MCP registration, audio send/receive, heartbeat, and reconnect behavior.
- `BuddyDictationManager.swift` captures microphone audio and streams PCM16 24 kHz mono chunks.
- `GlobalPushToTalkShortcutMonitor.swift` uses a listen-only CGEvent tap for global modifier-only push-to-talk.
- `AuthManager.swift` handles magic-link auth with the Worker and stores the session in Keychain.

## Integration Boundaries

- Local macOS tools stay local:
  - `CalendarIntegration.swift` uses EventKit.
  - `RemindersIntegration.swift` uses EventKit.
  - `SystemControlsIntegration.swift` uses AppKit, AppleScript, or CGEvent/system shortcuts.
  - `AppLauncherIntegration.swift` uses `NSWorkspace`.
  - `CompanionScreenCaptureUtility.swift` uses ScreenCaptureKit.
- Web service integrations should go through Composio MCP. Do not add one-off OAuth flows or direct API clients for Slack, Gmail, Spotify, GitHub, Notion, Linear, or similar services unless explicitly asked.
- Screen context is on demand. Do not capture or send screenshots on every key press.

## Invariants

- Keep `CompanionManager` and UI-observed state on `@MainActor`.
- Keep the realtime socket persistent. Do not connect/disconnect per utterance.
- Preserve the heartbeat/reconnect lifecycle unless the task is specifically about connection reliability.
- Preserve barge-in behavior: push-to-talk should interrupt current model playback before starting a new capture.
- The closed notch should remain small and unobtrusive; expansion should happen on hover, onboarding/auth/settings/file input, or useful task output.
- File and image context should be attached before `requestResponse()`.
- Do not rename `Auren*` files or symbols just for branding cleanup. Some legacy names remain in active code.

## Risky Files

Ask or state the exact reason before changing these:

- `RealtimeClient.swift` - protocol, heartbeat, tool dispatch, MCP, audio playback.
- `CompanionManager.swift` - central state transitions.
- `GlobalPushToTalkShortcutMonitor.swift` - global event tap behavior.
- `NotchPanelController.swift` and `NotchUIModel.swift` - geometry, animation, click-through surface.
- `DesignSystem.swift` - shared tokens and button styles.
- `Info.plist` and `leanring-buddy.entitlements` - permissions, URL scheme, sandbox/capabilities.

## Validation Notes

- Preferred app verification is Xcode on macOS, not terminal `xcodebuild`.
- On Windows, limit validation to static checks: changed-file review, `rg` for callers/imports, and project file membership if files are added.
- If adding a new Swift file, confirm it is included in `leanring-buddy.xcodeproj/project.pbxproj`.
- If removing a symbol, remove only imports or code made unused by your change. Do not remove pre-existing dead code opportunistically.
