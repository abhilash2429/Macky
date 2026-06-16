# AGENTS.md - Speed Codebase Context

This file is for AI coding agents working anywhere in this repository. Read it first, then read the nearest nested `AGENTS.md` before modifying files in a subfolder.

## Goal

Speed is a macOS voice assistant that lives in the notch. The intended product behavior is documented in `SPEED.md`: press the push-to-talk shortcut, speak, and let the app route audio through a realtime voice model, execute local or web tools, and show only the notch UI unless useful work needs an expanded panel.

The current implementation is a heavily reworked fork. Treat the product direction in `SPEED.md` and the current code as the source of truth. Do not assume old Clicky, Auren, makesomething, or Boring Notch behavior still applies unless current files prove it.

## Repository Map

- `leanring-buddy/` - Active macOS app target. SwiftUI plus AppKit, notch panel UI, push-to-talk audio capture, realtime client, local tool integrations, auth UI, and permissions.
- `leanring-buddy.xcodeproj/` - Xcode project configuration for the app. Edit only when files, targets, build settings, package products, or signing settings actually need project changes.
- `worker/` - Cloudflare Worker TypeScript proxy. Owns `/realtime`, `/composio-config`, and magic-link auth routes.
- `scripts/` - Release automation for the macOS app. Treat as production deployment tooling.
- `boring.notch/` - Checked-in upstream/reference Boring Notch project. Use for notch geometry and behavior reference. Do not modify it unless the task explicitly targets that folder.
- `SPEED.md` - Product and architecture brief. Read before product behavior, UI, voice pipeline, integration, or branding changes.

## Hard Constraints

- The `leanring-buddy` directory name, scheme name, and project file name are legacy and intentionally kept. Do not rename them unless explicitly asked.
- Build and run the macOS app through Xcode on macOS. Do not run terminal `xcodebuild` for normal verification because it can disturb macOS TCC permissions for Accessibility, Screen Recording, and Microphone.
- Preserve existing dirty work. This repo may already contain large uncommitted changes; do not revert or clean up unrelated files.
- Do not commit secrets, API keys, `.dev.vars`, Keychain material, Apple signing material, or OAuth tokens.
- Keep changes surgical. If a file has unrelated old branding or dead code, mention it separately unless the task is specifically to clean it up.

## Cross-Cutting Architecture

- The app starts from `leanring-buddy/leanring_buddyApp.swift`, creates `CompanionManager`, and hosts all visible product UI in `NotchPanelController`.
- `CompanionManager` is the app-level state coordinator. It owns voice state, operation state, permissions, push-to-talk transitions, pending attachments, pending Composio connection links, and history shown in the panel.
- `RealtimeClient` owns the persistent WebSocket to the Worker, session setup, heartbeat/reconnect behavior, realtime protocol parsing, audio playback, local tool registration, MCP call tracking, and context attachment.
- `BuddyDictationManager` captures microphone audio and converts it to PCM16 24 kHz mono chunks for realtime input.
- `GlobalPushToTalkShortcutMonitor` owns the global CGEvent tap and hotkey matching. Be conservative here; event tap bugs break the core interaction.
- Local macOS integrations live in Swift (`CalendarIntegration`, `RemindersIntegration`, `SystemControlsIntegration`, `AppLauncherIntegration`, `CompanionScreenCaptureUtility`). Web service integrations should go through Composio MCP via the Worker/session config.
- `worker/src/index.ts` keeps secrets off the client. The app connects to the Worker, and the Worker connects to Azure/OpenAI realtime and Composio.

## Coding Rules

- Before editing, read the file you will change and the direct caller/callee path. For Swift state or UI work, start with `CompanionManager` plus the view/controller using that state.
- Prefer existing patterns: `@MainActor` for UI/state owners, `@Published` for UI-observed state, async/await for new asynchronous Swift code, and small static integration methods for local tools.
- Do not introduce speculative abstractions. This codebase is easier to work in when each milestone remains explicit.
- Keep names descriptive. Do not shorten product-state names or arguments just to reduce line length.
- Comments should explain non-obvious timing, macOS API behavior, permission behavior, or protocol constraints. Do not add comments that restate obvious code.
- If current code and `SPEED.md` disagree, pause and surface the conflict before changing behavior.

## Verification

- For Swift app changes: verify through Xcode on macOS when possible. In this Windows workspace, do static verification by reading changed code, checking imports/callers with `rg`, and clearly state that an Xcode build was not run.
- For Worker changes: from `worker/`, use `npx wrangler dev` or `npx wrangler deploy` only when the task requires it and secrets are configured. Otherwise inspect TypeScript and route behavior.
- For script changes: do not run release scripts without explicit approval. Dry-run by reading command flow and checking affected paths/variables.
- For documentation-only changes: verify the docs exist at the intended paths and that no stale agent instructions contradict the new standard `AGENTS.md` files.

## Nested Instructions

- `leanring-buddy/AGENTS.md` applies to the active macOS app.
- `leanring-buddy.xcodeproj/AGENTS.md` applies to Xcode project metadata.
- `worker/AGENTS.md` applies to the Cloudflare Worker.
- `scripts/AGENTS.md` applies to release automation.
- `boring.notch/AGENTS.md` applies to the upstream reference tree.
