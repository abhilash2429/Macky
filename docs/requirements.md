# REQUIREMENTS.md — Speed v1

## What This Is

macOS AI assistant that lives in the notch. Voice-in, action-out. You talk to it, it does the thing. No typing, no switching apps, no clicking around.

## Hard Constraints

- macOS 14.2+ only (ScreenCaptureKit requirement)
- Direct .dmg distribution — not Mac App Store
- GPT-Realtime-2 exclusively for voice pipeline — no fallback to older models
- macOS-native integrations (Calendar, Reminders, system) are Swift-only — no MCP
- Web integrations route through Composio MCP gateway exclusively — no custom OAuth
- All API secrets live on the Cloudflare Worker — nothing sensitive in the binary
- Free during beta, paid subscription after launch

## UI

- Assistant lives in the notch, edge-to-edge, blends with the notch background
- Triggers (key press, active states) do NOT expand the notch
- All active states (listening, thinking, speaking) are contained within the notch footprint via animation
- Notch expands ONLY when: user hovers over notch, or app has something to show (multi-step task enumeration)
- On non-notch displays: full-width floating bar pinned to top center of screen
- Push-to-talk hotkey is configurable by user (default: ctrl+option)

### Notch States
- **Idle** — notch looks like a notch, nothing visible
- **Listening** — dim waveform inside notch reacting to voice input
- **Thinking** — slow soft pulse within notch footprint
- **Speaking** — quiet waveform showing model audio output
- **Executing multi-step** — notch expands, live enumeration with spinners/checkmarks
- **Hover** — notch expands showing current status and last action
- **Done** — if expanded: holds final state briefly then collapses. If not expanded: brief fade back to idle.

### Live Enumeration (Claude Code style)
When executing multi-step tasks the expanded notch shows:
```
⠸ opening your slack
✓ found rahul's dm
⠸ sending message
✓ message sent
⠸ creating reminder for tomorrow
✓ done
```
- Spinner cycles on active step
- Checkmark lands when step completes
- Words come from model (not hardcoded) — system prompt instructs active-present narration

## Voice Pipeline

- GPT-Realtime-2 over persistent WebSocket
- WebSocket opens on app launch, stays open, heartbeat every 25s
- Model receives raw audio stream directly — no separate STT step
- Screen capture is on-demand: model calls `get_screen_context` function tool when needed
- Swift app responds to tool call with ScreenCaptureKit grab
- Cloudflare Worker acts as WebSocket proxy only

## Integrations — v1

### Web Services (via Composio MCP gateway)
- Spotify: play song, pause, skip, volume, queue, play playlist
- Slack: send message to person or channel, search recent messages
- Gmail: read unread, send reply, compose draft

### macOS-Native (direct Swift)
- Apple Calendar: read today/tomorrow schedule, add event, find free slot (EventKit)
- Apple Reminders: add reminder, set time (EventKit + UserNotifications)
- Chrome: open URL, new tab, search (AppleScript)
- System: volume up/down, do not disturb on/off, lock screen (AppleScript + NSWorkspace)

## Auth and Onboarding

- Email magic link — no password
- Composio sub-user created and tied to user's email on first login
- First launch: setup screen listing integrations, user clicks connect per service
- macOS permissions (microphone, screen recording, accessibility, calendar, reminders) requested at first launch via standard system dialogs
- OAuth tokens managed by Composio, transparent to user after initial setup

## System Prompt Requirements (model behavior)
- Acknowledge immediately before any tool call fires
- Narrate each tool call as short active-present phrase before executing
- Never go silent while tools are in flight
- Call `get_screen_context` only when user's request explicitly or implicitly references screen
- Keep responses concise — voice interface, not a chat window
- Deliver confirmation vocally after completing any action

## Analytics
- PostHog retained from Clicky codebase
- Track: integration usage frequency, interactions per session, onboarding completion rate, error rates per tool

## What's NOT in v1
- Ambient always-on screen recording
- Persistent memory across sessions
- Local vector search over past activity
- GitHub, Notion, Linear, Jira, Apple Music, Finder integrations
- Always-listening mode (push-to-talk only)
- Windows or Linux support