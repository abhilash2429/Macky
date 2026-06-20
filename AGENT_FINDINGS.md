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
