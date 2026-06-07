# END TO END — Auren Development Guide

---

## Before First Line of Code

### 1. Place the project files

Open terminal, navigate to your Clicky repo root:

```bash
cd /path/to/your/clicky/repo
ls  # should show: leanring-buddy.xcodeproj, worker/, AGENTS.md, README.md
```

Drop in the new files:

```bash
# Replace root AGENTS.md
cp ~/Downloads/AGENTS.md ./AGENTS.md

cp ~/Downloads/REQUIREMENTS.md ./REQUIREMENTS.md
cp ~/Downloads/BACKLOG.md ./BACKLOG.md

# worker-AGENTS.md goes INTO worker/ folder, renamed
cp ~/Downloads/worker-AGENTS.md ./worker/AGENTS.md
```

### 2. Create Worker secrets file

```bash
touch worker/.dev.vars
```

Open it and paste — fill in your actual OpenAI key:

```
OPENAI_API_KEY=sk-your-openai-key-here
```

Check it's gitignored:

```bash
cat .gitignore | grep dev.vars
# If nothing prints:
echo "worker/.dev.vars" >> .gitignore
```

### 3. Install Worker dependencies

```bash
cd worker && npm install && cd ..
```

### 4. Verify Xcode builds clean

```bash
open leanring-buddy.xcodeproj
```

- Select `leanring-buddy` scheme
- Signing & Capabilities → set your Apple team
- Cmd+R

Clicky should appear in your menu bar. If it doesn't build, fix it before proceeding. Do not build on broken code.

### 5. First commit — your rollback baseline

```bash
git add .
git commit -m "chore: project foundation — AGENTS.md, REQUIREMENTS.md, BACKLOG.md"
```

---

## The Development Loop (Repeat for Every Milestone)

Every single milestone follows this exact loop. No exceptions.

```
1. git commit (checkpoint before starting)
2. write AGENT_TASKS.md
3. open claude (claude code)
4. paste the opening prompt
5. review the plan
6. say "go"
7. verify it works
8. git commit
9. archive milestone in BACKLOG.md
10. clear AGENT_TASKS.md
```

---

## Milestone 1: Cloudflare Worker WebSocket Proxy

### Checkpoint commit
```bash
git add . && git commit -m "checkpoint: before milestone 1"
```

### Write AGENT_TASKS.md
Create `AGENT_TASKS.md` at repo root with exactly this:

```markdown
# Milestone 1: Cloudflare Worker WebSocket Proxy

## Context
Read AGENTS.md, worker/AGENTS.md, REQUIREMENTS.md, and BACKLOG.md milestone 1 section before doing anything.

## Goal
Replace all existing routes in worker/src/index.ts with a single /realtime WebSocket proxy route. The route upgrades HTTP to WebSocket and forwards bytes between the client and OpenAI's Realtime API at wss://api.openai.com/v1/realtime?model=gpt-realtime-2. Zero computation. Zero parsing. Pure byte forwarding.

## Technical details
- OpenAI upstream connection requires headers: Authorization: Bearer [OPENAI_API_KEY] and OpenAI-Beta: realtime=v1
- OPENAI_API_KEY must be read from env.OPENAI_API_KEY (Cloudflare Worker secret), never hardcoded
- Use Cloudflare's WebSocketPair to proxy: one end returned to client, other end connected upstream to OpenAI
- Remove existing routes: /chat, /tts, /transcribe-token — they are all replaced

## Files to touch
- worker/src/index.ts (modify only)

## Files off-limits
- Everything in leanring-buddy/ (not this milestone)

## Done when
- GET /realtime upgrades to WebSocket successfully
- Frames sent by client reach OpenAI (OpenAI sends back session.created JSON)
- Old routes removed
- No secrets hardcoded

## If unsure → stop and ask, don't guess
```

### Open Claude Code
```bash
claude
```

### Opening prompt — paste this exactly:
```
/plan

Read AGENTS.md, worker/AGENTS.md, and AGENT_TASKS.md fully before planning.

Then read worker/src/index.ts to understand the existing code.

Plan how to replace the existing routes with a /realtime WebSocket proxy route that forwards bytes between the connecting client and OpenAI's Realtime API at wss://api.openai.com/v1/realtime?model=gpt-realtime-2. The OPENAI_API_KEY from env secrets is passed as Authorization Bearer header to OpenAI upstream. The Worker does zero computation — just proxies bytes using Cloudflare's WebSocketPair API.

Do not write code yet. Plan only.
```

Review the plan. If it's only touching `worker/src/index.ts` and describes a WebSocketPair proxy with no message parsing — say **"go"**.

### Verify
```bash
cd worker && npx wrangler dev
```

New terminal tab:
```bash
npx wscat -c ws://localhost:8787/realtime
```

You should connect. OpenAI will send back a `session.created` JSON event within 1-2 seconds. If you see that JSON — Milestone 1 is done.

### Commit and archive
```bash
cd ..
git add . && git commit -m "feat: Worker WebSocket proxy for GPT-Realtime-2"
```

Open `BACKLOG.md` → move Milestone 1 to `## Archive`. Clear `AGENT_TASKS.md`.

---

## Milestone 2: RealtimeClient.swift

### Checkpoint commit
```bash
git add . && git commit -m "checkpoint: before milestone 2"
```

### Write AGENT_TASKS.md
```markdown
# Milestone 2: RealtimeClient.swift — Session + Function Calling Foundation

## Context
Read AGENTS.md, REQUIREMENTS.md, and BACKLOG.md milestone 2 section fully before doing anything.
Then read CompanionManager.swift fully to understand the state machine before touching it.
Then read ClaudeAPI.swift, ElevenLabsTTSClient.swift, AssemblyAIStreamingTranscriptionProvider.swift to understand what is being replaced.

## Goal
Create RealtimeClient.swift — single file managing the GPT-Realtime-2 WebSocket connection.
Delete the old API client files. Wire CompanionManager to use RealtimeClient.

## Decisions already made — do not deviate
- WebSocket connects to the Cloudflare Worker /realtime endpoint, not directly to OpenAI
- WebSocket opens on app launch and stays open. Heartbeat ping every 25 seconds.
- RealtimeClient handles: session.created, response.audio.delta, response.audio.done, response.function_call_arguments.done, error events
- On session.created → send session.update to configure the session
- Function tool registration: registerTool(name:description:schema:handler:) method — handlers return a String (JSON), client sends conversation.item.create with type "function_call_output" then response.create
- voiceState: @Published enum (idle/listening/processing/responding) drives all UI

## Files
CREATE: leanring-buddy/RealtimeClient.swift
MODIFY: leanring-buddy/CompanionManager.swift — remove all Claude/ElevenLabs/AssemblyAI references, add realtimeClient property
MODIFY: leanring-buddy/leanring_buddyApp.swift — remove old client initialization
DELETE: leanring-buddy/ClaudeAPI.swift
DELETE: leanring-buddy/ElevenLabsTTSClient.swift
DELETE: leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift
DELETE: leanring-buddy/OpenAIAudioTranscriptionProvider.swift
DELETE: leanring-buddy/AppleSpeechTranscriptionProvider.swift
DELETE: leanring-buddy/BuddyTranscriptionProvider.swift
DELETE: leanring-buddy/OpenAIAPI.swift

## Files off-limits
- OverlayWindow.swift, DesignSystem.swift, ClickyAnalytics.swift, GlobalPushToTalkShortcutMonitor.swift
- BuddyDictationManager.swift (audio wiring is Milestone 3)
- worker/ (done in Milestone 1)

## Done when
- App builds in Xcode (Cmd+R) with no errors
- On launch: WebSocket connects, console logs "session.created received"
- Console logs heartbeat ping every 25s
- registerTool() method exists and compiles correctly
- All deleted files are removed from Xcode project

## If unsure → stop and ask, don't guess
```

### Opening prompt:
```
/plan

Read AGENTS.md, REQUIREMENTS.md, and AGENT_TASKS.md fully.
Then read these files in order: CompanionManager.swift, ClaudeAPI.swift, ElevenLabsTTSClient.swift, AssemblyAIStreamingTranscriptionProvider.swift, leanring_buddyApp.swift.

Plan the implementation of RealtimeClient.swift and the changes to CompanionManager.swift and leanring_buddyApp.swift. Include the files that need to be deleted.

Do not write code yet. Plan only.
```

### Verify
Cmd+R in Xcode. Open Console.app or Xcode console. Check for:
- `session.created received` log
- `heartbeat ping` log appearing every 25s
- No build errors

### Commit and archive
```bash
git add . && git commit -m "feat: RealtimeClient replaces API layer"
```

---

## Milestone 3 and Beyond — The Pattern

From Milestone 3 onward, the pattern is identical. For each milestone:

**Step 1**: Read the milestone entry in BACKLOG.md carefully.

**Step 2**: Write `AGENT_TASKS.md` using this template:

```markdown
# Milestone N: [Name]

## Context
Read AGENTS.md, REQUIREMENTS.md, and BACKLOG.md milestone N section fully before doing anything.
Then read [list the specific files Claude needs to understand before touching anything].

## Goal
[Exact single-sentence goal from BACKLOG.md]

## Decisions already made — do not deviate
[Pull the architecture context from BACKLOG.md milestone entry]

## Files
[Copy exactly from BACKLOG.md milestone entry]

## Files off-limits
[Everything not listed above]

## Done when
[Copy the done criteria from BACKLOG.md]

## If unsure → stop and ask, don't guess
```

**Step 3**: Open Claude Code, paste this opening prompt:

```
/plan

Read AGENTS.md, REQUIREMENTS.md, and AGENT_TASKS.md fully.
Then read [the specific files relevant to this milestone].

Plan the implementation. Do not write code yet.
```

**Step 4**: Review the plan. Ask yourself:
- Is it only touching the files listed in AGENT_TASKS.md?
- Does it match the architecture decisions?
- Is anything unexpected in scope?

If yes to all — say **"go"**. If anything is off — correct it in chat before executing.

**Step 5**: Verify (Cmd+R in Xcode for Swift milestones, `npx wrangler dev` for Worker milestones).

**Step 6**: Commit.

**Step 7**: Archive milestone in BACKLOG.md, clear AGENT_TASKS.md.

---

## Things That Will Go Wrong and How to Handle Them

**Build errors after a milestone**: Do not start the next milestone. Tell Claude Code: `"The build is failing with this error: [paste error]. Fix only this, nothing else."` Commit the fix before moving on.

**Claude Code goes off-scope**: It starts touching files not in the task. Stop it immediately. `"Stop. You touched [file] which is off-limits for this milestone. Revert those changes and only touch what was specified."` Then git checkout the off-limits file.

**Session goes sideways beyond repair**: 
```bash
git checkout .  # reverts all uncommitted changes
```
You're back to your last checkpoint commit. Restart the milestone from scratch.

**Claude Code asks a question mid-task**: Answer it with the relevant decision from AGENTS.md or BACKLOG.md. Never let it guess.

**A milestone touches more than 3 files unexpectedly**: Split it. Stop the session, commit what's working, start a new session with only the remaining work.

---

## Quick Reference

| Milestone | Verify with |
|-----------|-------------|
| 1 Worker | `npx wscat -c ws://localhost:8787/realtime` → see session.created |
| 2 RealtimeClient | Xcode console → session.created + heartbeat logs |
| 3 Audio | Hold ctrl+option, speak, hear model respond |
| 4 Screen Capture | Say "what's on my screen" → model describes it |
| 5 Notch Base | Launch app → notch looks like hardware notch |
| 6 Notch States | Hold hotkey → waveform in notch |
| 7 Expanded Panel | Hover over notch → panel drops down |
| 8 System Controls | "Turn volume up" → volume increases |
| 9 Calendar | "What's on my calendar today" → real events |
| 10 Reminders | "Remind me to..." → appears in Reminders.app |
| 11 Composio | "Play Back in Black" → Spotify plays |
| 12 Hotkey | Remap hotkey → persists after restart |
| 13 System Prompt | Every interaction gets immediate acknowledgment |
| 14 Auth | Fresh launch → email prompt → magic link → logged in |
| 15 Onboarding | Fresh install → all permissions + integrations flow |
| 16 .dmg | Installs on separate Mac, no Gatekeeper warning |
| 17 PostHog | Dashboard shows events firing |
