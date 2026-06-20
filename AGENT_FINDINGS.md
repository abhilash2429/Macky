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
