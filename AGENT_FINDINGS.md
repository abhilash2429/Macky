# AGENT_FINDINGS.md — Macky Production Hardening Pass

Audit trail for the 12-phase production-hardening pass defined in `AGENT_TASKS (1).md`.
Each phase below records: the **claim** as stated in the task file, the **verification**
method, the **verdict** (`confirmed` / `partially confirmed` / `refuted` /
`inconclusive`), the **evidence** (file:line references), and the **action taken**.

This file is the audit trail — written so that someone with no memory of the work can
understand *why* each change happened. No Xcode build was run for any phase (per root
`AGENTS.md`: local `xcodebuild` disturbs TCC permissions; static verification is
sufficient).

**Pass started:** 2026-06-20

---

## Phase 0 — Baseline

- **Goal:** establish a clean starting point and this audit-trail file before any other
  phase runs.
- **Verification:** `git status --short` on branch `master` returned a clean working tree
  — the previously-dirty files listed in the session-start snapshot
  (`AurenFileDropPanel.swift`, `AurenPanel.swift`, `CompanionManager.swift`,
  `RealtimeClient.swift`, `SystemControlsIntegration.swift`, `leanring-buddy.entitlements`)
  were already committed in `61d9a68 updated changes`. Nothing uncommitted to checkpoint.
- **Action:** created this `AGENT_FINDINGS.md` as the first commit of the pass. Each
  subsequent phase appends its own entry and commits separately so a wrong fix is easy to
  isolate and revert.
- **Decisions locked by Ab before execution (see plan):**
  1. Phase 4 item 4 — keep `require_approval: "never"` as a deliberate, documented tradeoff.
  2. Phase 8 — build a minimal analytics layer (new `MackyAnalytics.swift`, since
     `ClickyAnalytics.swift` does not exist) + wire PLCrashReporter.
  3. Phase 9 — keep the camera entitlement (likely a planned feature); still remove
     `clearDetectedElementLocation()` and the now-dead `awaitingApproval`.
  4. Phase 10 — client-side merge of the two connector lists only; no Worker change.

---

## Phase 1 — Unify the tool-activity state machine

- **Claim:** three independent "is a tool running" trackers
  (`CompanionManager.activeToolCount`, `RealtimeClient.isToolActive`,
  `activeMCPCallIDs`); the MCP completion path clears `isToolActive` based only on
  `activeMCPCallIDs.isEmpty` with no generation guard, so an MCP call's delayed cleanup
  can flip the spinner off while a native call started in that window is still running
  (notch flickers out of the executing state mid multi-step task).
- **Verification:** re-read both files. Confirmed (with line numbers, pre-edit):
  - `dispatchFunctionCall` set `isToolActive = true` at start and `isToolActive = false`
    at handler finish (RealtimeClient.swift ~986 / ~1017), guarded only by
    `activityGeneration` for the *cosmetic* fade, not for the boolean itself.
  - `handleMCPOutputItem` completion branch did `if activeMCPCallIDs.isEmpty { isToolActive
    = false }` (~756), and the start branch did `isToolActive = true` (~771).
  - The two paths were genuinely independent: the native `activityGeneration` and the MCP
    `activeMCPCallIDs` set do not couple, so nothing prevented an MCP completion from
    flipping the flag off during a concurrent native call.
  - `CompanionManager.$isToolActive` sink only *partially* shielded the UI: it re-sets
    `toolCallActive = true` when active flips true and only clears when `activeToolCount ==
    0`. But it sets `operationState = .executing` on the `active==true` edge, so a spurious
    false→ (no native edge) leaves the manager out of sync with reality. The race was real
    at the `RealtimeClient` level regardless.
  - **Discrepancy from the claim:** the delayed-clear sleep is **1.2s**, not 1.5s as the
    task stated. Mechanism otherwise as described.
  - **Found during verification:** `teardown()` cleared neither `activeMCPCallIDs` nor the
    activity flag, so a disconnect mid-MCP-call already leaked a stuck "executing" state.
- **Verdict:** **confirmed** (with the 1.2s timing correction).
- **Action (RealtimeClient.swift only, callback surface unchanged):**
  - Added `inFlightCallCount` + a single `adjustInFlight(_:)` writer that is now the *only*
    writer of `isToolActive` (`isToolActive = inFlightCallCount > 0`).
  - Native start → `adjustInFlight(+1)`; native finish → `adjustInFlight(-1)`.
  - MCP start (insert branch) → `adjustInFlight(+1)`; MCP completion (only when the call
    was tracked, i.e. `remove` succeeded) → `adjustInFlight(-1)`.
  - Reset the MCP set + reconcile the count in `teardown()` so a reconnect can't strand the
    spinner (fixes the pre-existing leak found during verification, within phase boundary).
  - Kept the per-path `activityGeneration` guard for the cosmetic `currentActivity` "✓→nil"
    fade so a stale fade still can't wipe a newer call's narration.
- **Trace proving the fix (per "Done when"):**
  MCP call A starts → `adjustInFlight(+1)` → count 1, `isToolActive=true`.
  A's `output_item` completed event arrives → `remove(A)` succeeds → `adjustInFlight(-1)` →
  count 0, `isToolActive=false`, and A schedules its 1.2s cosmetic fade. **Before** the
  fade fires, native call B dispatches → `adjustInFlight(+1)` → count 1, `isToolActive=true`.
  A's fade closure fires 1.2s later: it only touches `currentActivity` (gated by A's
  generation, which B already superseded, so it early-returns) — it **never** touches
  `isToolActive`. B finishes → `adjustInFlight(-1)` → count 0 → `isToolActive=false`. So
  `isToolActive` stays true for the entire duration of B. Symmetric for native-A→MCP-B.
- **No Xcode build run** — static verification (read + `rg` of every `adjustInFlight` /
  `isToolActive` site confirming balanced +1/-1 and a single writer).

## Phase 2 — Narration source of truth

- **Claim:** `CompanionManager.beginToolActivity` (wired to `onToolCallStarted`) computes
  its own narration via the hardcoded `narrationPhrase(for:)` substring table and writes
  it to `narrationText` — the same UI text that `RealtimeClient`'s real model-sourced
  narration (`currentActivity`) also writes via a separate Combine sink — making it a race
  between two sources, with the hardcoded one also producing wrong/generic labels
  (`create_calendar_event` and `get_calendar_events` both → "checking your calendar";
  `lock_screen`/etc. → generic "working"). Contradicts MACKY.md ("words come from the model").
- **Verification:**
  - Two writers of `narrationText`/`operationState` confirmed: `handleActivityChange`
    (CompanionManager.swift:870, fed by `realtimeClient.$currentActivity`) sets
    `narrationText = activity`; `beginToolActivity` (:605, fed by `onToolCallStarted`) set
    `narrationText = Self.narrationPhrase(for:)`.
  - **Event ordering (determines who actually wins):** in `RealtimeClient.dispatchFunctionCall`,
    `currentActivity = pendingNarration` is set *synchronously* (RealtimeClient.swift:984)
    **before** the `Task` that fires `onToolCallStarted` is even created (:990). Combine
    delivers `$currentActivity` on the main queue first, so `handleActivityChange` populates
    `narrationText` with the model phrase before `beginToolActivity` runs. So the model value
    is reliably present for narrated calls — the hardcoded write was overwriting it.
  - **Verify step 2 (would full removal blank fast tools?):** yes — the system prompt tells
    the model to run instant tools silently ("Run every tool silently"), so for those calls
    `pendingNarration`/`currentActivity` is nil and the hardcoded table is the only label.
    Full deletion would leave those calls with no executing label. → demote to fallback, per
    the phase's own decision rule, not delete.
- **Verdict:** **confirmed.**
- **Action (CompanionManager.swift only):**
  - `beginToolActivity` now does `let label = narrationText ?? Self.narrationPhrase(for:)`,
    so the model-sourced `narrationText` (already published) wins and the hardcoded table is
    consulted only when the model didn't narrate the call.
  - Rewrote `narrationPhrase(for:)`'s doc comment to mark it explicitly FALLBACK ONLY so a
    future reader doesn't re-promote it to the primary mechanism.
- **Done-when trace:** for a narrated call, `narrationText` holds the model transcript phrase
  (set by `handleActivityChange` from `$currentActivity`) before `beginToolActivity` runs, so
  the `??` keeps the model phrase and the displayed executing label matches the model — not
  the hardcoded table. MACKY.md narration contract upheld; no doc rewrite needed (Phase 11
  will add a one-line fallback caveat if warranted).
- **No Xcode build run** — static verification (read + traced Combine delivery order).

## Phase 3 — Move Spotify/Music polling off the main thread

- **Claim:** `MackyMusicManager` calls `NSAppleScript(source:).executeAndReturnError`
  directly on the main actor inside a 1s `Timer`, blocking the main thread for the full
  Apple Event round-trip each tick — unlike `SystemControlsIntegration.runAppleScript`,
  which already runs detached.
- **Verification:**
  - `MackyMusicManager` is `@MainActor` (AurenPanel.swift:1081). `scriptValue`/`scriptValues`
    called `NSAppleScript().executeAndReturnError` **synchronously** on the main actor
    (pre-edit ~1377–1403), reached from `refresh()` via `updateFromSpotify`/`updateFromMusic`,
    which the 1s `Timer` invoked (~1109).
  - `NSAppleScript.executeAndReturnError` is a synchronous, blocking Apple Event call — a
    real main-thread stall, equivalent in effect to `Process.waitUntilExit()`. Confirmed.
  - `SystemControlsIntegration.runAppleScript` already uses `Task.detached` + `Process`
    (osascript) for exactly this reason — the correct pattern existed in-repo.
  - **Severity moderation confirmed:** `startPolling`/`stopPolling` *are* scoped to
    `BoringStyleMusicCard`'s `onAppear`/`onDisappear` (AurenPanel.swift ~168–169), so the
    stall only occurs while the music card is visible — real, but not constant background
    stalling.
- **Verdict:** **confirmed** (severity moderated by the on-screen scoping).
- **Action (AurenPanel.swift only):**
  - Added `nonisolated static func executeScript(_:) async` that runs `NSAppleScript` inside
    a detached utility Task, mirroring `runAppleScript`. The blocking call now runs off the
    main thread; only `@Published` assignment stays on `@MainActor`.
  - Read path made async: `refresh()` / `updateFromSpotify()` / `updateFromMusic()` /
    `scriptValue` / `scriptValues` are now `async` and `await` the off-main executor; the
    poll timer calls `Task { @MainActor in await refresh() }`.
  - Write path (transport): `runScript`, `seek`, `toggleShuffle`, `toggleRepeat` route through
    a fire-and-forget `runScriptDetached(_:)` so a transport tap never blocks the UI; their
    follow-up reads use the async `refresh()`. Transport methods stay synchronous `func`s so
    SwiftUI button actions are unchanged.
  - Verified no external caller of `refresh`/`updateFrom*` exists outside AurenPanel.swift,
    and that the unrelated calendar manager's own `refresh() async` (same file) is a separate
    type.
- **Done-when:** no AppleScript execution in `MackyMusicManager` runs synchronously on
  `@MainActor`; `@Published` assignment is the only main-actor work in the hot path. `rg`
  confirms every `scriptValue(s)` call site is now `await`.
- **No Xcode build run** — static verification.

## Phase 4 — System prompt gaps + approval-gating decision

Four-part claim. Items 1–3 are prompt-engineering; item 4 is a product-risk decision
(stop-and-ask, resolved by Ab before this phase).

- **Item 1 — no current date/time in the prompt.** *Verified:* `mackySystemPrompt` is a
  static string with no `Date()`; `sendSessionUpdate` passed it verbatim as `instructions`
  with no templating (RealtimeClient.swift:958 pre-edit). No date injected anywhere.
  *Verdict:* **confirmed.** *Action:* added `sessionInstructions(now:)` that appends the
  current local date/time to the static prompt, built fresh on every `sendSessionUpdate`
  (so it refreshes on reconnect). `instructions` now uses `Self.sessionInstructions()`.
- **Item 2 — no connect/authorization-link instruction.** *Verified:* prompt had no guidance
  for the `COMPOSIO_MANAGE_CONNECTIONS` connect-link flow. *Verdict:* **confirmed.** *Action:*
  added one explicit prompt rule: on a connect/auth link, tell the user (one spoken line) to
  finish connecting in the browser that just opened, don't read the link aloud, don't retry
  until they confirm.
- **Item 3 — "judge for yourself" narrate/skip discretion.** *Verified:* the prompt does NOT
  ask the model to judge per-call whether a tool "takes a real moment." It already gives a
  *deterministic* rule: "Never narrate your process… Run every tool silently and speak only
  once you have the result." (RealtimeClient.swift ~880–884.) There is no per-call discretion
  to remove. *Verdict:* **refuted** — the deterministic rule the phase wanted already exists.
  *Action:* none (no change needed; logged so it isn't "fixed" into a contradiction).
- **Item 4 — `require_approval: "never"`, `awaitingApproval` never set.** *Verified:*
  `require_approval: "never"` is exactly what's sent for the Composio MCP tool entry
  (RealtimeClient.swift:926); `AssistantOperationState.awaitingApproval` is defined
  (CompanionManager.swift:32) with `activeStatusText` support but has zero assignment sites.
  *Verdict:* **confirmed → product decision, not auto-fixed.** *Decision (Ab, 2026-06-20):*
  **keep `require_approval: "never"`** as a deliberate latency tradeoff. Recorded as a decision
  in `MACKY.md` ("auth and onboarding ▸ approvals") so it isn't re-litigated. No
  `require_approval` code change. `awaitingApproval` is now confirmed dead → removed in Phase 9.
- **Found during verification:** the "never narrate" prompt rule and the notch's
  `currentActivity` narration are consistent — the notch shows the model's *spoken* words
  (transcript), which under this rule are post-action confirmations, not process narration.
  Phase 2's change (model phrase wins) does not conflict with this prompt rule.
- **No Xcode build run** — static verification.

## Phase 5 — Lock down connect-link parsing, remove debug logging

- **Claim:** a `// TEMP` `print("🧩 [MCP-CAPTURE]" …)` debug block and a "provisional…
  intentionally tolerant… until locked in" comment on `parseConnectionLink` shipped in the
  live connector-authorization path.
- **Verification:**
  - `[MCP-CAPTURE]` `// TEMP` block confirmed at RealtimeClient.swift ~665–671 (logged the
    full raw frame for any mcp / response.output_item event).
  - The "intentionally tolerant… until locked in" comment confirmed at ~742–744.
  - A second debug print at ~788 logged the connect link **including the full OAuth redirect
    URL** — sensitive, should not be in device logs.
  - The real `item.output` shape cannot be confirmed statically: the Worker (`worker/src/index.ts`)
    only mints the Composio Tool Router session and returns `{ url, key }`; it does not
    constrain or document the per-call `mcp_call` output shape, and no captured `[MCP-CAPTURE]`
    frame is available in this environment. So the parser shape remains genuinely unverified.
- **Verdict:** **confirmed** (debug leftovers present); parsing-shape correctness **inconclusive —
  needs a live session capture**.
- **Action (RealtimeClient.swift only):**
  - Removed the `// TEMP` `[MCP-CAPTURE]` print block entirely (unconditionally — pure debug
    leftover, no production purpose).
  - Removed the URL from the connect-link print (now logs only the toolkit slug, not the
    OAuth redirect URL).
  - Left the tolerant `parseConnectionLink` logic in place (correct per the decision rule —
    do not guess a narrower implementation without a live capture). Reworded the stale comment
    so it no longer claims an active capture effort (the capture mechanism is now removed) and
    instead states the shape is unverified and the tolerance is deliberate.
- **Open item:** `parseConnectionLink`'s handling of the real Composio `mcp_call` output shape
  remains unverified and should be closed out with a live `COMPOSIO_MANAGE_CONNECTIONS` capture.
  Listed for Ab in the Phase 12 deferred-items roundup.
- **Done-when:** `rg "MCP-CAPTURE"` → zero hits in the shipped path. Confirmed.
- **No Xcode build run** — static verification.

## Phase 6 — Centralize the Worker base URL

- **Claim:** the Worker host is hardcoded independently in 5 places across 3 files, and the
  self-hosting docs only mention updating 2 of them (`AuthManager.workerBaseURL` +
  `RealtimeClient`'s two URLs), never `CompanionManager`'s two — so a self-hoster following
  the docs ends up with connector calls still hitting the original production Worker.
- **Verification:** `rg realtime-proxy.speedmac.workers.dev` over Swift confirmed exactly 5
  independent literals, no shared constant:
  - AuthManager.swift:35 (`workerBaseURL`, base for auth routes, concatenated with a path)
  - RealtimeClient.swift:154 (`workerRealtimeURL`), :158 (`composioConfigURL`)
  - CompanionManager.swift:247 (`composioConnectURL`), :249 (`composioConnectionsURL`)
  - README §12 / root AGENTS.md / leanring-buddy/AGENTS.md name only AuthManager +
    RealtimeClient; none mention CompanionManager's two URLs. Gap confirmed.
  - The two CompanionManager URLs are plain Worker routes (`/composio-connect`,
    `/composio-connections`), not a separate concern — they must point at the same host.
- **Verdict:** **confirmed.**
- **Action:**
  - Added `leanring-buddy/WorkerEndpoints.swift` — one `enum WorkerEndpoints` with
    `baseHost` (the single value to change when self-hosting) and derived `httpsBase`,
    `realtimeURL`, `composioConfigURL`, `composioConnectURL`, `composioConnectionsURL`.
  - Rewired all 5 call sites to derive from it.
  - The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (no per-file pbxproj
    entries; confirmed `ConnectorRegistry.swift` has no explicit entry either), so the new
    file is picked up automatically by its presence in `leanring-buddy/`.
- **Done-when:** `rg realtime-proxy.speedmac.workers.dev --type swift` → exactly **one** hit
  (`WorkerEndpoints.swift:15`). Confirmed. Docs corrected in Phase 11.
- **No Xcode build run** — static verification.

## Phase 7 — Latency fixes (five independent sub-claims)

### 7a — Composio config fetch blocks socket open
- *Claim:* `connect()` awaits `fetchComposioConfig()` (up to 5s) before `openSocket()`,
  serializing two independent ops and adding up to 5s to launch.
- *Verified:* confirmed — pre-edit `connect()` (RealtimeClient.swift ~539–547) awaited the
  fetch inside a Task, then opened the socket. `sendSessionUpdate` (which consumes
  `composioMCPURL`/`composioKey`) only runs on `session.created`, so there is no correctness
  reason for the serialization — the fetch can overlap the handshake.
- *Verdict:* **confirmed.** *Action:* `connect()` now calls `openSocket()` immediately and
  fetches config concurrently. Added `sessionUpdateSent`; if the config resolves after the
  first `session.update`, `fetchComposioConfig` sends a follow-up update (same mechanism
  `setContinuousTurnDetection` uses) so connectors still work that session.

### 7b — No audio buffering across reconnect
- *Claim:* `sendJSON` no-ops when `webSocketTask == nil`; a mid-utterance reconnect drops
  in-flight audio with no replay.
- *Verified:* confirmed — `sendJSON` returns early on nil task (RealtimeClient.swift:1179);
  `sendAudio` routed straight through it with no queuing; 1s reconnect backoff. A drop during
  an active push-to-talk press is plausible (not purely theoretical) on a flaky network.
- *Verdict:* **confirmed.** *Action:* chose **surface-the-drop over blind replay** (the task's
  fallback option) because a reconnect clears the *server-side* input buffer — replaying only
  part of an utterance would commit a fragment that transcribes wrong. Added
  `audioDroppedDuringUtterance`: set when `sendAudio`/`commitAudio` hit a nil socket; on
  commit, surface via `lastError` ("Lost connection while you were talking — try again.") and
  skip committing the partial utterance. Reset at capture start (`clearAudioBuffer`).

### 7c — Full session.update resend on a UI toggle
- *Claim:* `setContinuousTurnDetection` resends the whole tool list + prompt + MCP entry just
  to flip `turn_detection`.
- *Verified:* confirmed it calls `sendSessionUpdate()` (full resend). BUT: a partial update
  would need verified Azure GA merge semantics for *omitting* `tools`/`instructions` and for
  *clearing* `turn_detection` (push-to-talk needs it set to null, not merely omitted) — not
  determinable statically without a live session. And this runs only on a manual
  continuous-listening toggle, **never per utterance**, so it is off the latency-critical path.
- *Verdict:* **partially confirmed — not fixed.** The full resend is correct, just not minimal,
  and narrowing it risks silently breaking VAD toggling for no user-perceptible gain. Left the
  code; added a doc comment explaining why the full resend is deliberate. (No guess per rules.)

### 7d — open_app rescans the filesystem every call
- *Claim:* `installedApps()` walks four dirs via `contentsOfDirectory` on every invocation,
  no caching.
- *Verified:* confirmed (AppLauncherIntegration.swift ~94–114, no cache).
- *Verdict:* **confirmed.** *Action:* added a static 60s TTL cache (`cachedApps` +
  `cacheTimestamp`) so the common case (resolving an already-installed app) skips the rescan;
  a freshly-installed app is still resolvable within 60s.

### 7e — Multi-monitor capture always captures every display
- *Claim:* `captureAllScreensAsJPEG` unconditionally captures every display even though
  screen-context is almost always about one visible thing.
- *Verified:* **partially refuted** as stated — the function *already* sorts the cursor screen
  first and labels it, but it does capture+encode every display and had no single-display fast
  path and no way for the model to request a specific display.
- *Verdict:* **confirmed (the wasteful capture), partially refuted (cursor handling already
  existed).** *Action:* `captureAllScreensAsJPEG(cursorScreenOnly:)` now defaults to capturing
  only the cursor display (`prefix(1)` of the cursor-first sort); `get_screen_context` gained an
  `all_screens` boolean (default false) whose description tells the model to set it only when
  the user clearly means multiple screens. All-display capability retained as the opt-in path.

### Volume-by-percent latency (documented, not auto-fixed)
- *Verified:* confirmed — `setVolume(toPercent:)` issues up to 16 `tapVolumeKey` taps spaced
  25ms (`Task.sleep(25_000_000)`) so the native bezel animates each step
  (SystemControlsIntegration.swift). Deliberate native-feedback-vs-latency tradeoff.
- *Verdict:* **confirmed-but-not-fixed** per the phase. No code change (needs Ab to revisit the
  tradeoff if desired).

- **Docs synced:** `leanring-buddy/AGENTS.md` "Active Architecture Notes" updated for the
  concurrent config fetch, the no-replay/surface-the-drop reconnect behavior, and the
  cursor-display default for screen context.
- **No Xcode build run** — static verification (read + `rg` of all touched call sites).
