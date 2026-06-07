# BACKLOG.md — Auren v1
<!-- One milestone = one Claude Code session. Commit before every session. Never start next milestone on broken code. -->
<!-- When starting a session: tell Claude Code to read AGENTS.md + REQUIREMENTS.md + this file before doing anything. -->

---

## Architecture Decisions Claude Code Must Know
<!-- Read this section before every session. These are final decisions. Do not deviate. -->

- Voice model is **GPT-Realtime-2** — not gpt-4o-realtime, not any other model
- **WebSocket opens on app launch, stays open the entire session** — heartbeat ping every 25s keeps it alive
- **macOS-native integrations (Calendar, Reminders, system controls, Chrome) use Swift directly** — EventKit, UserNotifications, AppleScript, NSWorkspace. Never MCP for these.
- **Web service integrations (Slack, Gmail, Spotify) use Composio MCP gateway** — one URL passed to session config, Composio handles everything
- **Screen capture is on-demand** — model calls a `get_screen_context` function tool when it needs to see the screen. Swift responds with a ScreenCaptureKit grab. Never auto-capture.
- **Cloudflare Worker is a WebSocket proxy only** — forwards bytes, does zero computation, never parses message content
- **Never run xcodebuild from terminal** — always Cmd+R in Xcode
- **The "leanring" typo stays** — do not rename project, directory, or scheme

---

## Milestone 1: Cloudflare Worker — WebSocket Proxy

**Goal**: Replace the existing Worker routes with a `/realtime` WebSocket proxy that forwards bytes between the Swift app and OpenAI's Realtime API. This is the only route needed right now.

**Why this first**: Every Swift milestone depends on this connection existing. Nothing else can be tested until bytes flow through the Worker to OpenAI.

**Architecture context**:
- Current Worker has three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI) — all three get removed
- New route: `GET /realtime` — upgrades HTTP to WebSocket, connects upstream to `wss://api.openai.com/v1/realtime?model=gpt-realtime-2`, forwards all frames bidirectionally
- OpenAI requires `Authorization: Bearer YOUR_KEY` and `OpenAI-Beta: realtime=v1` headers on the upstream connection
- Cloudflare Workers handle WebSocket proxying via WebSocketPair — the Worker creates a pair, returns one end to the client, forwards everything from the other end to OpenAI
- Zero computation in this route. No JSON parsing. No message inspection. Pure byte forwarding.
- OPENAI_API_KEY lives as a Worker secret, read from `env.OPENAI_API_KEY`

**Files**:
- Modify: `worker/src/index.ts` — delete old routes, add /realtime WebSocket proxy
- No other files

**Done when**:
- `npx wscat -c ws://localhost:8787/realtime` connects without error
- Sending a raw JSON frame through wscat reaches OpenAI (OpenAI will respond with `session.created` event)
- Worker logs show connection established, no errors
- Old routes (/chat, /tts, /transcribe-token) are removed

**Do not**:
- Parse or log message content in the proxy route
- Add any business logic to the Worker in this milestone
- Touch any Swift files

---

## Milestone 2: RealtimeClient.swift — Session + Function Calling Foundation

**Goal**: Create `RealtimeClient.swift` — the single file that manages the entire GPT-Realtime-2 WebSocket connection. This replaces ClaudeAPI.swift, ElevenLabsTTSClient.swift, AssemblyAIStreamingTranscriptionProvider.swift, and all transcription provider files.

**Why**: This is the core of the new architecture. Everything — audio streaming, function calls, model responses — flows through this one client. Build it right here and every integration milestone becomes straightforward.

**Architecture context**:
- RealtimeClient owns one persistent URLSessionWebSocketTask connecting to `[WORKER_URL]/realtime`
- On `applicationDidFinishLaunching`: call `realtimeClient.connect()`
- Heartbeat: send WebSocket ping frame every 25 seconds via a repeating Timer — if pong doesn't return within 5s, reconnect
- OpenAI Realtime protocol events RealtimeClient must handle:
  - `session.created` — connection confirmed, send `session.update` to configure tools and instructions
  - `response.audio.delta` — base64 audio chunk, decode and play via AVAudioEngine
  - `response.audio.done` — audio playback complete
  - `response.function_call_arguments.done` — model wants to call a tool, dispatch to registered handler
  - `conversation.item.created` — model text response (for enumeration parsing)
  - `error` — log and surface to CompanionManager
- Function tool registration: RealtimeClient has a `registerTool(name: String, description: String, schema: [String: Any], handler: ([String: Any]) async throws -> String)` method. Handlers return a JSON string that gets sent back as a `conversation.item.create` with `type: "function_call_output"` followed by `response.create`
- `@Published var voiceState: VoiceState` — drives all UI state (idle/listening/processing/responding)
- Audio output: received audio.delta chunks are queued and played via AVAudioPlayer or AVAudioEngine

**Files**:
- Create: `leanring-buddy/RealtimeClient.swift`
- Modify: `leanring-buddy/CompanionManager.swift` — remove all references to Claude/ElevenLabs/AssemblyAI, add `realtimeClient: RealtimeClient` property
- Delete: `leanring-buddy/ClaudeAPI.swift`
- Delete: `leanring-buddy/ElevenLabsTTSClient.swift`
- Delete: `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift`
- Delete: `leanring-buddy/OpenAIAudioTranscriptionProvider.swift`
- Delete: `leanring-buddy/AppleSpeechTranscriptionProvider.swift`
- Delete: `leanring-buddy/BuddyTranscriptionProvider.swift`
- Delete: `leanring-buddy/OpenAIAPI.swift`
- Modify: `leanring-buddy/leanring_buddyApp.swift` — remove old API client initialization

**Done when**:
- App builds and runs in Xcode without errors
- On launch, WebSocket connects to Worker and OpenAI responds with `session.created`
- Console logs confirm: connection established, heartbeat firing every 25s
- `registerTool()` method exists and compiles
- Old API client files are gone from the project

**Do not**:
- Wire audio capture yet (that's Milestone 3)
- Build any UI changes (that's Milestone 6+)
- Add integrations yet (that's Milestone 5+)
- Keep any AssemblyAI, ElevenLabs, or old Claude API code

---

## Milestone 3: Audio Pipeline — Mic In + Audio Out

**Goal**: Push-to-talk works end to end. Hold hotkey → microphone audio streams to GPT-Realtime-2 → model responds with voice → you hear it through speakers.

**Architecture context**:
- Push-to-talk hotkey defaults to ctrl+option, handled by `GlobalPushToTalkShortcutMonitor.swift` (CGEvent tap — do not change this)
- On key-down: start AVAudioEngine capture, convert mic buffers to PCM16 mono 24kHz, send `input_audio_buffer.append` events to RealtimeClient as base64-encoded PCM16 chunks
- On key-up: send `input_audio_buffer.commit` then `response.create` to trigger model response
- Audio output: `response.audio.delta` events contain base64 PCM16 audio — decode, queue, play via AVAudioEngine output node
- BuddyDictationManager.swift currently handles AVAudioEngine — strip out all the transcription provider logic, keep only the raw mic capture and audio level reporting (for waveform UI)
- BuddyAudioConversionSupport.swift has PCM16 conversion helpers — keep this file, it's useful

**Files**:
- Modify: `leanring-buddy/BuddyDictationManager.swift` — remove transcription provider calls, keep AVAudioEngine capture, wire audio buffers to RealtimeClient
- Modify: `leanring-buddy/RealtimeClient.swift` — add `sendAudio(_ data: Data)`, `commitAudio()`, `requestResponse()` methods, add audio output playback
- Keep: `leanring-buddy/BuddyAudioConversionSupport.swift`
- Keep: `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift` — do not touch

**Done when**:
- Holding ctrl+option and speaking → model hears you and responds verbally
- Audio plays through speakers without distortion
- Releasing key stops capture and triggers response
- CompanionManager voiceState transitions: idle → listening → processing → responding → idle

**Do not**:
- Change the CGEvent tap in GlobalPushToTalkShortcutMonitor.swift
- Add any UI changes in this milestone

---

## Milestone 4: Screen Capture Function Tool

**Goal**: Register `get_screen_context` as a function tool in the GPT-Realtime-2 session. When model calls it, Swift captures all connected screens with ScreenCaptureKit and returns the image data.

**Architecture context**:
- Model decides when to call this — never auto-capture
- Tool name: `get_screen_context`, no parameters required
- Handler: call `CompanionScreenCaptureUtility.captureAllScreens()`, returns array of screen images with labels ("Screen 1", "Screen 2" etc)
- Return format to model: JSON string `{"screens": [{"label": "Screen 1", "description": "..."}]}` — but for image data, use the Realtime API's image input format (base64 PNG in the function_call_output)
- `CompanionScreenCaptureUtility.swift` already exists and works — use it as-is

**Files**:
- Modify: `leanring-buddy/RealtimeClient.swift` — register `get_screen_context` tool in `session.update` config
- Modify: `leanring-buddy/CompanionScreenCaptureUtility.swift` — minor: ensure it returns data compatible with tool response format
- Keep: everything else unchanged

**Done when**:
- Saying "what's on my screen?" triggers the `get_screen_context` tool call
- Screenshot is captured and returned to model
- Model accurately describes what's on screen in its verbal response

---

## Milestone 5: Notch UI — Base Structure

**Goal**: Replace the full-screen cursor overlay with a notch-covering NSPanel. At idle the panel is invisible — blends perfectly with the notch hardware cutout.

**Architecture context**:
- The existing `OverlayWindow.swift` is a full-screen transparent NSPanel that hosts the cursor and response text — replace this entirely with the new notch panel
- New panel is NOT full-screen. It's a small panel positioned at top center of the primary display, exactly covering the notch dimensions
- MacBook notch is approximately 126pt wide × 37pt tall at the top center — panel must match these dimensions at idle
- Panel uses `NSPanel` with `NSWindow.StyleMask.borderless`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`, `backgroundColor = .black`, `isOpaque = false`
- On non-notch displays: floating bar 200pt wide × 37pt tall at top center, slightly rounded corners, black background
- `CompanionResponseOverlay.swift` (the old cursor response view) gets replaced by `NotchView.swift`

**Files**:
- Create: `leanring-buddy/NotchView.swift` — SwiftUI view that renders inside the notch panel, idle state only in this milestone
- Modify: `leanring-buddy/OverlayWindow.swift` — replace full-screen cursor panel with notch panel, keep NSPanel pattern
- Do not touch `CompanionResponseOverlay.swift` yet, just stop using it

**Done when**:
- App launches and the notch looks exactly like the hardware notch (invisible panel)
- On a non-notch display a small black floating bar appears at top center
- No cursor overlay, no response text floating around

**Do not**:
- Add any animations or states yet (Milestone 6)
- Touch CompanionManager voice logic
- Touch BuddyDictationManager

---

## Milestone 6: Notch UI — Active States (Within Notch)

**Goal**: Listening, thinking, and speaking states all animate within the notch footprint. The notch never expands for these states.

**Architecture context**:
- Listening: dim waveform inside notch, amplitude driven by `BuddyDictationManager.audioLevel` (already published)
- Thinking: slow repeating pulse animation on the notch — opacity cycles 0.4→0.8→0.4 over 1.2s
- Speaking: waveform reacts to audio output level from RealtimeClient's playback
- All animations are SwiftUI `.animation` modifiers, nothing leaves the notch bounds
- CompanionManager.voiceState drives which state renders — this is already published, just subscribe in NotchView

**Files**:
- Modify: `leanring-buddy/NotchView.swift` — add listening/thinking/speaking state views
- Modify: `leanring-buddy/OverlayWindow.swift` — pass voiceState binding to NotchView
- No other files

**Done when**:
- Holding hotkey: waveform appears in notch reacting to voice
- Releasing key: waveform stops, slow pulse begins
- Model responding: different waveform pattern shows
- Notch size never changes during any of these states

---

## Milestone 7: Notch UI — Expanded Panel + Enumeration

**Goal**: Panel expands downward on hover. Panel also expands when model starts narrating a multi-step task. Live enumeration shows inside expanded panel with spinners and checkmarks.

**Architecture context**:
- Expansion trigger 1: `NSTrackingArea` on the notch panel detects mouse enter → expand
- Expansion trigger 2: RealtimeClient detects model narrating a tool call step → calls `showEnumeration(step: String)` on CompanionManager → panel expands
- Expansion animation: SwiftUI `.animation(.spring(response: 0.3))` height increase downward from notch bottom
- Expanded panel shows:
  - Current status text (what model just said it's doing)
  - Enumeration list: completed steps (✓ prefix, gray), active step (⠸ spinning, white), future steps not shown yet
- Spinner character: cycle through `["⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]` on 0.1s timer
- How steps get populated: RealtimeClient parses `conversation.item.created` events — when model says something like "opening your slack" before a tool call, that phrase gets added as an active enumeration step. When the tool call succeeds, that step flips to ✓
- Collapse: mouse leaves notch area AND no active task running → collapse after 0.8s delay

**Files**:
- Modify: `leanring-buddy/NotchView.swift` — add expanded state, enumeration list view, hover detection
- Create: `leanring-buddy/EnumerationView.swift` — the spinner/checkmark step list component
- Modify: `leanring-buddy/CompanionManager.swift` — add `enumerationSteps: [EnumerationStep]` published property
- Modify: `leanring-buddy/RealtimeClient.swift` — parse narration phrases from conversation events, call CompanionManager step methods

**Done when**:
- Hovering over notch expands panel cleanly
- Moving cursor away collapses panel (with delay if task running)
- Multi-step task shows live enumeration with spinners flipping to checkmarks
- Single-step tasks (play a song, set reminder) never trigger expansion

---

## Milestone 8: System Controls + Chrome

**Goal**: Volume control, do not disturb, lock screen, open URL in Chrome, new Chrome tab — all via AppleScript and NSWorkspace from Swift function tools.

**Why before Calendar/Reminders**: These require zero external permissions or OAuth. Good integration milestone to validate the function calling pattern end to end before touching EventKit.

**Architecture context**:
- All implemented as registered function tools in RealtimeClient
- Volume up/down: `NSAppleScript` with `set volume output volume ((output volume of (get volume settings)) + 10)`
- DND toggle: AppleScript via `osascript` targeting Focus/DND system preference
- Lock screen: `NSWorkspace.shared.screenSaver...` or `osascript` with `tell application "System Events" to keystroke "q" using {command down, control down}`
- Open URL in Chrome: `NSWorkspace.shared.open(url, withAppBundleIdentifier: "com.google.Chrome", ...)`
- New Chrome tab: AppleScript `tell application "Google Chrome" to open location "about:newtab"`

**Files**:
- Create: `leanring-buddy/SystemControlsIntegration.swift` — all 5 tools
- Modify: `leanring-buddy/RealtimeClient.swift` — register the 5 tools at session.update

**Done when**:
- "Turn volume up" works
- "Turn on do not disturb" works
- "Lock the screen" works
- "Open github.com in Chrome" works
- "Open a new Chrome tab" works

---

## Milestone 9: Apple Calendar Integration

**Goal**: Model can read today's schedule, tomorrow's schedule, add an event, and find a free time slot. All via EventKit in Swift responding to function tool calls.

**Architecture context**:
- EventKit requires `NSCalendarsUsageDescription` in Info.plist (already handle permission in onboarding — for now just request at first tool call if not granted)
- Tools to register: `get_calendar_events(date: String)`, `create_calendar_event(title: String, startDate: String, endDate: String, notes: String?)`, `find_free_slot(date: String, durationMinutes: Int)`
- Use `EKEventStore` — request access with `requestFullAccessToEvents` (iOS 17+/macOS 14+ API)
- Date parsing: model will pass ISO8601 strings or natural language — parse with `ISO8601DateFormatter` first, fallback to `DateFormatter`

**Files**:
- Create: `leanring-buddy/CalendarIntegration.swift`
- Modify: `leanring-buddy/RealtimeClient.swift` — register calendar tools
- Modify: `leanring-buddy/Info.plist` — add NSCalendarsUsageDescription if not present

**Done when**:
- "What's on my calendar today?" returns real events verbally
- "Add a meeting called Design Review at 3pm tomorrow" creates the event (verify in Calendar app)
- "Find me a free hour tomorrow afternoon" returns an available slot

---

## Milestone 10: Apple Reminders Integration

**Goal**: Model can create reminders with optional due dates. Via EventKit in Swift.

**Architecture context**:
- `EKReminder` via `EKEventStore` — same store instance as Calendar, request `requestFullAccessToReminders`
- Tool: `create_reminder(title: String, dueDate: String?, notes: String?)`
- Requires `NSRemindersUsageDescription` in Info.plist

**Files**:
- Create: `leanring-buddy/RemindersIntegration.swift`
- Modify: `leanring-buddy/RealtimeClient.swift` — register reminders tool
- Modify: `leanring-buddy/Info.plist` — add NSRemindersUsageDescription if not present

**Done when**:
- "Remind me to follow up with Rahul tomorrow at 9am" creates a reminder (verify in Reminders app)
- "Remind me to review the PR" creates a reminder with no specific time

---

## Milestone 11: Composio MCP — Slack, Gmail, Spotify

**Goal**: GPT-Realtime-2 session connects to the Composio MCP gateway. Model can send Slack messages, read Gmail, and control Spotify.

**Architecture context**:
- Composio provides a single MCP endpoint URL — get this from your Composio dashboard after setting up an app
- Pass it into session config in `session.update`: `{"mcp_servers": [{"type": "url", "url": "YOUR_COMPOSIO_URL", "headers": {"Authorization": "Bearer COMPOSIO_API_KEY"}}]}`
- The Composio API key lives as a Worker secret (`COMPOSIO_API_KEY`) — the Worker must pass it as a header when connecting to OpenAI, OR the Swift app reads it from a config endpoint on the Worker
- Cleaner approach: Swift app fetches a session token from a Worker endpoint `/composio-config` that returns the Composio URL + key, then Swift app passes them into the Realtime session config
- User's OAuth connections (their personal Slack/Gmail/Spotify) are tied to their Composio sub-user account — created at auth time (Milestone 14), but for testing use a hardcoded test sub-user first

**Files**:
- Modify: `leanring-buddy/RealtimeClient.swift` — add MCP server config to `session.update`
- Modify: `worker/src/index.ts` — add `GET /composio-config` endpoint that returns Composio URL and key from secrets
- No new Swift files

**Done when**:
- "Play Back in Black by AC/DC on Spotify" plays the song
- "Message [your own Slack handle] saying test" sends the Slack message
- "Read my latest unread Gmail" reads an email verbally

---

## Milestone 12: Configurable Hotkey

**Goal**: User can remap the push-to-talk shortcut. Preference persists in UserDefaults. Default is ctrl+option.

**Architecture context**:
- `GlobalPushToTalkShortcutMonitor.swift` currently has the hotkey hardcoded — make it read from UserDefaults with ctrl+option as default
- The CGEvent tap logic itself doesn't change — only which key combination it watches for
- Settings UI: a small view in `CompanionPanelView.swift` (the menu bar dropdown) with a "Record Shortcut" button that captures the next key combo the user presses

**Files**:
- Modify: `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift` — read hotkey from UserDefaults
- Modify: `leanring-buddy/CompanionPanelView.swift` — add hotkey remapping UI
- Create: `leanring-buddy/HotkeySettingsView.swift` — the recording UI component

**Done when**:
- User opens menu bar panel, clicks "Change Shortcut", presses new key combo
- New combo saves and persists after restart
- New combo triggers push-to-talk correctly

---

## Milestone 13: System Prompt

**Goal**: Write and wire the production system prompt that defines Auren's behavior as a voice assistant.

**What the prompt must enforce**:
- Acknowledge every request immediately before doing anything: "on it", "let me check", "give me a sec" — pick naturally based on context
- Before calling any tool, speak a short active-present narration phrase: "opening your slack", "checking your calendar", "searching spotify"
- Never go silent while a tool call is in flight
- Keep all verbal responses short — this is a voice interface, not a chat window
- After completing any action, confirm verbally in one short sentence
- Call `get_screen_context` only when the user refers to something on screen, asks "what's this", "what am I looking at", or similar

**Files**:
- Modify: `leanring-buddy/RealtimeClient.swift` — set `instructions` field in `session.update` config

**Done when**:
- Every interaction gets an immediate acknowledgment
- Every tool call is preceded by a narration phrase
- No silent gaps during execution
- Responses are consistently concise

---

## Milestone 14: User Auth — Magic Link

**Goal**: First launch shows an email prompt. User enters email, gets a magic link, clicks it, session is established. Auth state persists in Keychain. Composio sub-user created for this email.

**Architecture context**:
- Worker adds two routes: `POST /auth/magic-link` (takes email, sends link, stores pending token), `POST /auth/verify` (takes token, returns session JWT)
- Token storage in Worker: use Cloudflare KV store (create a binding called `AUTH_TOKENS`) — token expires in 15 minutes
- On verify success: create Composio sub-user for this email via Composio API, return session JWT + Composio user ID
- Swift side: `AuthManager.swift` checks Keychain for existing session on launch, if none → show auth UI
- Session JWT stored in macOS Keychain via `Security` framework
- Magic link opens a custom URL scheme registered in the app: `auren://auth?token=...` → app intercepts, calls verify endpoint

**Files**:
- Create: `leanring-buddy/AuthManager.swift`
- Create: `leanring-buddy/AuthView.swift` — email input + "check your email" state
- Modify: `worker/src/index.ts` — add /auth/magic-link and /auth/verify routes + KV binding
- Modify: `leanring-buddy/Info.plist` — register `auren` URL scheme
- Modify: `leanring-buddy/leanring_buddyApp.swift` — handle incoming URL scheme

**Done when**:
- Fresh launch shows email prompt
- Entering email and clicking the magic link logs in
- Reopening app does not prompt for email again (Keychain session persists)
- Composio sub-user exists for the email (verify in Composio dashboard)

---

## Milestone 15: Onboarding Flow

**Goal**: After first auth, walk user through granting all permissions and connecting integrations. Clean UI inside the existing menu bar panel.

**Onboarding steps in order**:
1. Microphone permission — request via AVAudioSession, show status
2. Screen Recording permission — open System Settings if denied, poll for grant
3. Accessibility permission — `AXIsProcessTrusted()`, open System Settings if denied
4. Calendar permission — request via EventKit
5. Reminders permission — request via EventKit
6. Connect Slack — open Composio OAuth URL in browser, poll for completion
7. Connect Gmail — same pattern
8. Connect Spotify — same pattern
9. Set hotkey — show HotkeySettingsView, can skip
10. Done — dismiss onboarding, notch panel ready

**Files**:
- Create: `leanring-buddy/OnboardingManager.swift` — tracks completion state in UserDefaults
- Create: `leanring-buddy/OnboardingView.swift` — step-by-step UI in a panel
- Modify: `leanring-buddy/WindowPositionManager.swift` — show onboarding window on first launch

**Done when**:
- Fresh install after auth shows onboarding
- Each permission step requests correctly and shows granted/denied status
- OAuth integrations open browser and detect completion
- Completing onboarding dismisses the screen and never shows again

---

## Milestone 16: .dmg Build + Notarization

**Goal**: A signed, notarized .dmg that installs on any Mac running macOS 14.2+ without Gatekeeper warnings.

**Architecture context**:
- Requires paid Apple Developer account ($99/year)
- Xcode archive → export with Developer ID signing
- Notarize via `notarytool`: `xcrun notarytool submit app.zip --apple-id ... --team-id ... --password ...`
- Staple the notarization ticket: `xcrun stapler staple Auren.app`
- Create .dmg with `create-dmg` npm package: `npx create-dmg Auren.app`

**Files**:
- Create: `build.sh` — script that archives, exports, notarizes, staples, and creates .dmg
- Modify: Xcode project signing settings — set to Developer ID (not development)

**Done when**:
- .dmg installs on a separate Mac that has never had the dev version
- App opens without Gatekeeper warning
- All permissions work on a fresh install

---

## Milestone 17: PostHog Analytics Wiring

**Goal**: Wire new events for Auren-specific interactions. The PostHog integration itself (ClickyAnalytics.swift) already exists — just add the new event calls.

**Events to add**:
- `voice_interaction_started` — every time hotkey is pressed
- `tool_called` — every function tool call with `tool_name` property
- `integration_used` — Slack/Gmail/Spotify/Calendar/Reminders/SystemControls with integration name
- `onboarding_step_completed` — each step with step name
- `auth_completed` — magic link verified
- `error_tool_failed` — tool call threw error with tool name + error type

**Files**:
- Modify: `leanring-buddy/ClickyAnalytics.swift` — add new event methods
- Modify: `leanring-buddy/RealtimeClient.swift` — call analytics on tool calls
- Modify: `leanring-buddy/OnboardingView.swift` — call analytics on step completions

**Done when**:
- PostHog dashboard shows all 6 event types firing in a real session

---

## Archive
<!-- Move completed milestones here after committing -->
