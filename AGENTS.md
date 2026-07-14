# AGENTS.md — Macky (repository root)

This is the README and operating manual for AI coding agents working anywhere in this
repository. Read it first, then read the nearest nested `AGENTS.md` before modifying
files in a subfolder. A short **User Instructions** section for humans is at the end.

---

## 1. What Macky Is

Macky is a **macOS voice assistant that lives in the notch**. It is not a chatbot or a
copilot you open and type into. You press a push-to-talk shortcut, speak, and the app
routes your audio through a realtime voice model, executes local or cloud tools, and
talks back — usually in under half a second. Voice in, action out.

The full product brief lives in [`MACKY.md`](MACKY.md). Read it before any change that
touches product behavior, UI, the voice pipeline, integrations, or branding. When the
current code and `MACKY.md` disagree, **pause and surface the conflict** before changing
behavior — do not silently pick one.

Core ideas from the brief:

- The assistant covers the notch edge to edge. Idle, it looks like the notch.
- Listening / thinking / speaking are shown by subtle animation **inside** the notch
  footprint — it does not expand for these states.
- The panel only expands on hover, for onboarding/auth/settings, for file input, or when
  a multi-step task has live steps worth showing (Claude Code-style enumeration with
  spinners and checkmarks). Expansion is earned, never automatic.
- On displays without a notch, it falls back to a full-width floating bar pinned top
  center.

### Heritage

Macky is a heavily reworked fork of **Clicky** (an open-source MIT-licensed macOS
assistant). The macOS UI primitives are kept — the `NSPanel`, ScreenCaptureKit usage,
the CGEvent push-to-talk tap, and the design system. The old API brain (AssemblyAI +
Claude + ElevenLabs chain) was removed and replaced with one realtime voice model plus an
MCP-based integration layer.

Do **not** assume old Clicky, Auren, makesomething, or Boring Notch behavior still
applies unless current files prove it. Treat the product direction in `MACKY.md` and the
current code as the source of truth.

---

## 2. Architecture at a Glance

```
  ┌─────────────────────────┐         WebSocket          ┌──────────────────────┐
  │  Macky macOS app        │  ───────────────────────▶  │  Cloudflare Worker   │
  │  (leanring-buddy/)      │   /realtime (byte proxy)   │  (worker/)           │
  │                         │  ◀───────────────────────  │  "realtime-proxy"    │
  │  • Notch UI (NSPanel)   │                            │                      │
  │  • Push-to-talk capture │   GET /composio-config     │  • secrets live here │
  │  • RealtimeClient       │   POST /auth/magic-link    │  • /realtime proxy   │
  │  • Local macOS tools    │   POST /auth/verify        │  • Composio session  │
  └─────────────────────────┘                            └──────────┬───────────┘
            │                                                        │
            │ local tools (EventKit, AppKit,                         │ proxies to
            │ ScreenCaptureKit, NSWorkspace)                         ▼
            ▼                                          ┌──────────────────────────┐
   macOS-native actions                                │ Azure AI Foundry realtime │
   (Calendar, Reminders,                               │ endpoint, gpt-realtime-2.1│
    system controls, apps,                             └──────────────────────────┘
    screen capture)                                    ┌──────────────────────────┐
                                                       │ Composio MCP gateway      │
   Cloud services (Slack, Gmail,  ────────────────────▶│ (250+ web integrations)   │
   Spotify, GitHub, …) via MCP                         └──────────────────────────┘
```

- The app starts in `leanring-buddy/leanring_buddyApp.swift`, creates `CompanionManager`
  (the app-level state coordinator), and hosts all visible UI in `NotchPanelController`.
- `RealtimeClient` owns the persistent WebSocket to the Worker, session setup, the
  heartbeat/reconnect lifecycle, realtime protocol parsing, audio playback, local tool
  registration, MCP call tracking, and context attachment.
- `BuddyDictationManager` captures microphone audio as PCM16 24 kHz mono chunks.
- `GlobalPushToTalkShortcutMonitor` owns the global CGEvent tap and hotkey matching.
- The Worker (`worker/src/index.ts`) keeps every secret off the client. The app talks to
  the Worker; the Worker talks to Azure realtime and Composio. The app targets a
  **hosted** Worker by default — its host is defined in **one** place,
  `WorkerEndpoints.baseHost` (`leanring-buddy/WorkerEndpoints.swift`), which every Worker
  URL in the app (`AuthManager`, `RealtimeClient`, `CompanionManager`) derives from. Normal
  app users do not deploy a backend; self-hosting means deploying `worker/` and changing
  that single `baseHost`.
- **Two integration buckets:** macOS-native actions are implemented locally in Swift; web
  services go through the Composio MCP gateway wired into the realtime session config.

---

## 3. Repository Map

| Path | What it is | Nested guide |
|------|------------|--------------|
| `leanring-buddy/` | Active macOS app target (SwiftUI + AppKit): notch UI, push-to-talk, realtime client, local tools, auth, permissions. | `leanring-buddy/AGENTS.md` |
| `leanring-buddy.xcodeproj/` | Xcode project config: targets, build settings, SPM products, signing. | `leanring-buddy.xcodeproj/AGENTS.md` |
| `worker/` | Cloudflare Worker TypeScript proxy. Owns `/realtime`, `/composio-config`, and the magic-link auth routes. | `worker/AGENTS.md` |
| `scripts/` | Release automation (`release.sh`) for the macOS app. Production deployment tooling. | `scripts/AGENTS.md` |
| `MACKY.md` | Product and architecture brief. The source of truth for intended behavior. | — |

> The folder, scheme, and project file are all named `leanring-buddy` (note the typo).
> This is intentional legacy naming. **Do not rename it** unless explicitly asked.

---

## 4. Hard Constraints

- **Names are frozen.** The `leanring-buddy` directory name, scheme name, and project
  file name are legacy and intentionally kept. Do not rename them unless explicitly asked.
- **Build through Xcode on macOS.** Do not run terminal `xcodebuild` for normal
  verification — it can disturb macOS TCC permissions for Accessibility, Screen
  Recording, and Microphone. (CI uses `xcodebuild` with signing disabled, which is fine
  on a throwaway runner; your local machine is not throwaway.)
- **Preserve existing dirty work.** This repo may already contain large uncommitted
  changes; do not revert or clean up unrelated files.
- **Never commit secrets.** No API keys, `.dev.vars`, Keychain material, Apple signing
  material, or OAuth tokens.
- **Keep changes surgical.** If a file has unrelated old branding or dead code, mention
  it separately unless the task is specifically to clean it up. Some legacy `Auren*` and
  `makesomething` names remain in active code on purpose.

---

## 5. Coding Rules

- Before editing, read the file you will change and the direct caller/callee path. For
  Swift state or UI work, start with `CompanionManager` plus the view/controller using
  that state.
- Prefer existing patterns: `@MainActor` for UI/state owners, `@Published` for
  UI-observed state, async/await for new asynchronous Swift code, and small static
  integration methods for local tools.
- Do not introduce speculative abstractions. Each milestone is intentionally explicit;
  the codebase is easier to work in that way.
- Keep names descriptive. Do not shorten product-state names or arguments just to reduce
  line length.
- Comments should explain non-obvious timing, macOS API behavior, permission behavior, or
  protocol constraints — not restate obvious code.
- If current code and `MACKY.md` disagree, pause and surface the conflict before changing
  behavior.

---

## 6. Verification

- **Swift app changes:** verify through Xcode on macOS when possible. When you cannot
  build (no Xcode session available), do static verification — read the changed code,
  check imports/callers with `rg`, confirm new files are in the project — and clearly
  state that an Xcode build was not run.
- **Worker changes:** from `worker/`, use `npx wrangler dev` or `npx wrangler deploy`
  only when the task requires it and secrets are configured. Otherwise inspect the
  TypeScript and route behavior statically.
- **Script changes:** do not run release scripts without explicit approval. Dry-run by
  reading the command flow and checking affected paths/variables (`bash -n
  scripts/release.sh` for syntax).
- **Docs-only changes:** verify the docs exist at the intended paths and that no stale
  agent instructions contradict the standard `AGENTS.md` files.

---

## 7. Nested Instructions

- `leanring-buddy/AGENTS.md` — the active macOS app.
- `leanring-buddy.xcodeproj/AGENTS.md` — Xcode project metadata.
- `worker/AGENTS.md` — the Cloudflare Worker.
- `scripts/AGENTS.md` — release automation.

(There is no `boring.notch/` folder in this tree; ignore any older reference to one.)

---

## User Instructions

For a human getting this project running locally.

### Prerequisites
- **macOS 14.2+** and **Xcode** (the CI pins Xcode on `macos-15`).
- **Node.js** + `npx` for the Worker.
- A Cloudflare account with Wrangler authenticated (`npx wrangler login`) if you intend
  to run or deploy the Worker.

### Run the app
1. Open `leanring-buddy.xcodeproj` in Xcode.
2. Select the `leanring-buddy` scheme and build & run (⌘R). Building once also lets SPM
   download Sparkle and PostHog.
3. On first launch, grant the macOS permission prompts (Microphone, Accessibility, Screen
   Recording). These power push-to-talk, the global hotkey, and screen context.
4. Sign in via the magic-link flow (see `worker/AGENTS.md`) or click **Skip for now**
   during early testing, then **hold the push-to-talk shortcut, speak, and release**.

### Run the backend
- From `worker/`: `npx wrangler dev` for local, `npx wrangler deploy` to publish.
- Required secrets: `AZURE_OPENAI_API_KEY`, `COMPOSIO_API_KEY`, `RESEND_API_KEY`, plus the
  `AUTH_TOKENS` KV namespace. Set secrets with `npx wrangler secret put <NAME>`. See
  `worker/AGENTS.md`.

### Ship a release
- From the repo root: `./scripts/release.sh` (auto-bumps version/build) or
  `./scripts/release.sh <version> [build]`. This builds, signs, notarizes, packages a
  DMG, signs the Sparkle update, and creates a GitHub Release. See `scripts/AGENTS.md`
  for one-time setup (Developer ID cert, notarytool credentials,
  Sparkle key, `brew install create-dmg gh`).
