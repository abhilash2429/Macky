# AGENTS.md — SPEED (Auren)
<!-- Human-curated. Do not let the agent rewrite or extend this file autonomously. -->
<!-- Project codename: SPEED. App name: Auren. Tagline: "speed is the leverage" -->

## Stack

- **Language**: Swift 5.9+, SwiftUI + AppKit bridging
- **macOS target**: 14.2+ (Sonoma minimum — required for ScreenCaptureKit)
- **Xcode**: 15+
- **UI pattern**: MVVM, `@StateObject` / `@Published`, `@MainActor` isolation
- **Voice model**: GPT-Realtime-2 via persistent WebSocket
- **Web integrations**: Composio MCP gateway (single endpoint, 250+ services)
- **macOS-native integrations**: Direct Swift — EventKit, UserNotifications, AppleScript
- **Proxy**: Cloudflare Worker (TypeScript) — see `worker/AGENTS.md`
- **Analytics**: PostHog via `ClickyAnalytics.swift`
- **Auth**: Magic link email, Composio sub-user per account

## Commands

```bash
# Open project — always use this, never xcodebuild
open leanring-buddy.xcodeproj

# Build and run — Cmd+R in Xcode ONLY
# NEVER run xcodebuild from terminal — invalidates TCC permissions

# Worker dev (from /worker)
npx wrangler dev

# Worker deploy (from /worker)
npx wrangler deploy

# Worker secrets
npx wrangler secret put AZURE_OPENAI_API_KEY
npx wrangler secret put COMPOSIO_API_KEY
```

## Counterintuitive Conventions

**1. Never run xcodebuild from terminal.**
It invalidates TCC (Transparency, Consent, and Control) permissions. The app will lose screen recording, accessibility, and microphone access and need to re-request everything. Build and run exclusively through Xcode (Cmd+R).

**2. The "leanring" typo in the project directory and scheme is intentional.**
It's a legacy artifact. Do not rename the directory, the scheme, or the `.xcodeproj` file.

**3. WebSocket opens on app launch, stays open for the entire session.**
```swift
// CORRECT — open once at launch, keep alive with heartbeat
func applicationDidFinishLaunching() {
    realtimeClient.connect()
}

// WRONG — do not open/close per interaction
func onHotkeyPressed() {
    realtimeClient.connect() // adds handshake latency every time
}
```
The heartbeat ping fires every 25 seconds to keep the connection alive. Do not change this interval.

**4. macOS-native integrations use Swift directly — not MCP.**
Calendar → EventKit. Reminders → UserNotifications + EventKit. System controls → AppleScript via `NSAppleScript`. App launching → `NSWorkspace`. Do not route these through Composio or any MCP server.

**5. Screen capture is on-demand via function call — not automatic.**
The app does not send a screenshot with every interaction. The model calls a `get_screen_context` function tool when it decides it needs to see the screen. The Swift app responds to that tool call by taking a ScreenCaptureKit grab and returning the image data.
```swift
// Model requests screen → Swift executes capture → returns image
// Do NOT pre-capture on every key-down
```

**6. Composio MCP is for web services only.**
Slack, Gmail, Spotify, GitHub, Notion, Linear → Composio gateway. One URL passed into the GPT-Realtime-2 session config. Never build custom OAuth flows for these services.

**7. All UI state updates must be on @MainActor.**
```swift
// CORRECT
await MainActor.run {
    self.voiceState = .listening
}

// WRONG
self.voiceState = .listening // race condition if called from background thread
```

**8. NSPanel for all floating windows — not NSWindow or SwiftUI WindowGroup.**
The notch overlay, the expanded panel, all floating UI → `NSPanel` with `NSHostingView` hosting SwiftUI content. `NSPanel` is non-activating so it never steals keyboard focus.

**9. Use async/await throughout — no callbacks or completion handlers.**
```swift
// CORRECT
let transcript = try await transcriptionProvider.finalize()

// WRONG
transcriptionProvider.finalize { transcript in ... }
```

**10. One shared URLSession for streaming connections — never per-session.**
Creating and invalidating URLSession per connection corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

## Permission Tiers

**✅ Always do:**
- Match existing code style in the file you're editing
- Preserve all `@MainActor` annotations exactly as found
- Remove imports, variables, and functions your changes make unused
- Keep variable names long and descriptive (see global rules)
- Use async/await, never callbacks

**⚠️ Ask before doing:**
- Adding a new Swift Package dependency
- Modifying app entitlements (`.entitlements` file)
- Changing the WebSocket heartbeat interval or session lifecycle logic
- Modifying `worker/src/index.ts` routing logic
- Adding a new MCP server URL to session config
- Changing any Composio authentication flow

**🚫 Never do:**
- Run `xcodebuild` from terminal
- Rename the project directory, scheme, or `.xcodeproj` file (the "leanring" typo stays)
- Commit API keys, secrets, or tokens
- Force push to main
- Add docstrings, comments, or type annotations to code you did not change
- "Fix" the known non-blocking warnings: Swift 6 concurrency warnings, deprecated `onChange` in `OverlayWindow.swift`
- Refactor, reformat, or "improve" code outside the scope of the current task
- Touch `DesignSystem.swift` unless the task explicitly requires it

## Files Off-Limits Unless Explicitly Instructed

- `DesignSystem.swift` — design tokens, reference only
- `ClickyAnalytics.swift` — PostHog integration, do not restructure
- `AppBundleConfiguration.swift` — runtime config reader, do not modify
- `GlobalPushToTalkShortcutMonitor.swift` — CGEvent tap logic, proven working, do not touch

## Read First Before Modifying

Before touching any file, read these in order:
1. `CompanionManager.swift` — central state machine, understand the full state enum before changing anything
2. The file you're about to edit — read it fully, understand every function's purpose
3. Any file that imports or is imported by the file you're editing

If you cannot explain what a function does before you change it, stop and ask.