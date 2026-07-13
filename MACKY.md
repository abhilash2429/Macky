# what we're building

a macOS AI assistant that lives in the notch. not a chatbot, not a copilot, not another thing you have to open and type into. just — you press a button, talk, it does the thing.

that's the whole idea. your mac should just do what you tell it. play a song, message someone, check your calendar, open something, run a task in the background. no switching apps, no typing, no clicking around. voice in, action out.

---

## where it came from

built on top of clicky — an open source macOS AI assistant farza made before he went private and started heyclicky (yc s26, raised $10M). he left the original code MIT-licensed. it already does the hard macOS stuff — menu bar panel, screen capture across multiple monitors, push-to-talk with system-wide keyboard shortcuts, the overlay that renders over everything. none of that is trivial and it's already done.

we're keeping the macOS UI shell. we're gutting everything else and rebuilding the actual brain from scratch.

---

## the notch

the assistant lives in the notch. covers it edge to edge. when it's idle you don't notice it — it's just the notch, black, sitting there.
when you trigger it the notch stays the same size. it doesn't expand. instead it shows you it's alive through subtle animation within the notch itself — a dim waveform while you're talking, a soft pulse while it's thinking, a quiet glow when it's speaking back. it's all contained inside the notch footprint. unobtrusive. you know it's working but it's not in your face.
the panel only expands in two situations: you hover over the notch, or the app has something to actually show you — enumerated steps on a multi-step task, a response it wants you to read, something it needs you to see. the expansion is intentional, not automatic. it earns the screen space.
on external monitors without a notch it falls back to a full-width floating bar pinned to the top center. same behavior, same logic. when apple ships the M6 macbook pro with native dynamic island hardware late 2026, we map onto it directly.

---

## the voice pipeline

the old clicky codebase chains three services: assemblyAI for transcription, claude for thinking, elevenlabs for speech output. works but slow — minimum 1.5-2 seconds before you hear anything. that's not a voice interface, that's a slow chatbot with speakers.

we're replacing the whole voice chain with GPT-Realtime-2.1. one persistent websocket and one realtime voice brain, with no transcription/thinking/speech handoffs. it takes raw audio directly, reasons while you speak, and talks back in 250-500ms.

GPT-Realtime-2.1 builds on GPT-Realtime-2's GPT-5-class reasoning, MCP support, image input (it can see your screen), and 128K context across an entire session. it improves alphanumeric recognition, silence/noise handling, and interruption behavior. this is the right model. not gpt-4o realtime, not a previous generation — GPT-Realtime-2.1 specifically.

precise visual teaching is the one deliberate specialist path: when the realtime model decides the user needs an exact on-screen diagram, the app sends that single on-demand screenshot (plus optional accessibility target boxes) to GPT-5.6-sol through the Worker. GPT-5.6-sol returns validated top-left screenshot coordinates for highlights, arrows, labels, and pointing. for multi-stage tasks, a guide's final step can be marked advance=on_user_action: the overlay then waits for the user's own click, and the app pings the realtime model to re-capture the changed screen and teach the next single action. the realtime model remains the voice brain and narrates the guide; the specialist never owns the conversation.

cursor control is a separate local macOS tool, not part of the diagram renderer. it can move, click, double-click, right-click, middle-click, drag, and scroll when the user asks Macky to operate visible UI. coordinate actions always bind to a fresh captured display; generated teaching diagrams only point and never click.

---

## how an interaction works

you hold ctrl+option. the notch stays the same size — no expansion, no dramatic reveal. a dim waveform appears inside it reacting to your voice. you say what you want. you let go.

the model starts deciding before you've finished releasing the key. it figures out internally what it needs — does it need to look at your screen? does it need to call spotify? does it need to check your calendar and then message someone off the result? it reasons about that the same way a person would. you don't configure any of this.

while tools are running in the background it talks. not because we hardcoded a loading message — because the system prompt tells it to acknowledge immediately and keep talking while things are in flight. it says "on it" or "let me check that" or "give me a sec" and then delivers the actual answer once the tool result comes back. through all of this the notch stays contained. just a quiet pulse or waveform, nothing expanding.

the panel only opens if the task is multi-step and there's actually something worth showing you — the live enumeration of what it's doing. that's app-initiated. it earns the expansion. once it's done it collapses back. for simple interactions — play a song, set a reminder, message someone — the whole thing happens and ends inside the notch. you barely notice it happened except the thing got done.

---

## what it shows while working

when the request is multi-step the app expands the notch downward and shows you what's happening live. think of how claude code works in the terminal — it doesn't go silent, it prints each action as it happens, spinner on the active step, checkmark when done.
same thing here. if you say "message rahul on slack that the auth bug is fixed and add a reminder to follow up tomorrow" the panel opens and enumerates:

⠸ opening your slack
✓ found rahul's dm
⠸ sending message
✓ message sent
⠸ creating reminder for tomorrow
✓ done

each line appears as it happens. spinner cycles on whatever's active. checkmarks land as things complete. once everything's done it holds for a beat then collapses back to the notch.
the words come from the model — not hardcoded. the system prompt instructs it to narrate each tool call as a short active-present phrase before executing it. "searching your spotify" not "invoke_search called". reads like a person doing something, not an API log.
single-step tasks — play a song, set a reminder, send a quick message — never trigger the expansion at all. they happen inside the notch, model confirms vocally, done.

---

## the notch states

-- idle — notch looks like a notch. nothing visible.
-- listening — notch stays same size. dim waveform inside it reacting to your voice input, contained entirely within -- the notch.
-- thinking — notch stays same size. slow soft pulse, barely noticeable.
-- speaking — notch stays same size. quiet waveform showing the model's audio output.
-- executing multi-step task — notch expands downward. live enumerated steps appear with spinners and checkmarks in real time. this is app-initiated expansion because there's actually something to show.
user hovers — notch expands downward. shows current status, what it's doing, last action. collapses when cursor leaves.
-- done — if expanded, holds the final state for a beat then collapses. if not expanded, notch just goes back to idle with a brief fade.

---

## integrations

integrations work through MCP — model context protocol. instead of building custom connectors for every service, MCP servers are plugged in and the model knows how to call them. no custom glue code per integration.

GPT-Realtime-2.1 handles MCP natively — you pass the server URL into the session config at startup, the API handles all the tool calls automatically. the model calls a tool, the platform executes it, the result comes back, the model keeps talking. nothing interrupts the voice stream.

### the context window problem

loading too many MCP servers at once bloats the model's context fast — one server can eat 20K tokens, which out of 128K adds up quick. the fix is a gateway. instead of pointing the session at 10 separate MCP server URLs, you point it at one gateway endpoint that brokers access to all of them. the model only gets the tools relevant to the current task in context, not the entire catalogue.

we use composio as the gateway for all cloud-based services. one URL, 250+ platforms behind it — slack, gmail, github, notion, jira, spotify, linear, and hundreds more. composio also handles all the OAuth so the user connects each service once during setup and never thinks about auth again.

### the two buckets

**web services** (slack, gmail, spotify, github, notion, linear, etc.) — all handled through the composio MCP gateway. cloud-based, API-driven, one connection covers all of them.

**macOS-native apps** (apple calendar, apple reminders, apple mail, contacts, app launching, volume, system controls) — these are OS-level, not API-based. handled by LMCP, a local MCP server that runs on the user's machine and exposes 221 macOS tools using AppleScript and apple's native frameworks. runs locally, no cloud, GDPR-clean.

two MCP URLs in the session config. the model has access to both buckets simultaneously.

### v1 integrations

these are the ones that ship first. they cover 80% of what people actually ask a voice assistant to do:

- **spotify** — play a song, pause, skip, volume, queue, play a playlist
- **apple calendar** — read today/tomorrow, add an event, find a free slot
- **apple reminders** — add a reminder, set a time
- **slack** — send a message, search a channel
- **gmail** — read unread, send a reply, compose a draft
- **chrome** — open a URL, new tab, search something
- **system controls** — volume, do not disturb, lock screen

### after v1

- **github** — read issues, create an issue, check PR status
- **notion** — read pages, create entries
- **linear/jira** — read tickets, update status
- **apple music** — same as spotify for people who don't use spotify
- **finder/files** — open a file, find a document

---

## auth and onboarding

first launch shows a clean setup screen. user sees each integration listed and clicks connect. composio handles the OAuth flow for all web services. macOS-native permissions (calendar, reminders, mail) go through the standard apple permission dialogs. after that the model has access to everything that was connected. token refresh happens silently. user never touches auth again.

### approvals (decision)

**decision (2026-07-11): Composio MCP tools run with `require_approval: "never"` for normal clear commands** — Macky does not add a per-action confirmation step for routine messages, calendar/reminder creation, music, or system controls. this preserves the core voice-in/action-out loop: asking "should i send that?" before every Slack message or email would break the half-second interaction the product is built around. the model confirms ordinary actions after the tool succeeds.

the narrow exception is materially dangerous work: permanent deletion/discard, payments/purchases/transfers, cancellations, account/security changes, or another action with comparable irreversible harm. the model names the consequence and obtains an explicit voice confirmation before it calls that tool. this is conversational, not a new gating UI; `AssistantOperationState.awaitingApproval` remains retired.

---

## the cloudflare worker

all API calls go through a cloudflare worker proxy sitting between the swift app and GPT-Realtime-2.1. the app never talks to openAI directly. the real API key lives on the worker as a secret, nothing sensitive ships in the binary.

GPT-Realtime-2.1 uses a persistent WebSocket, not a request/response. the worker runs as a WebSocket proxy — app connects to worker, worker proxies to openAI's realtime endpoint, bytes flow through without the worker doing compute. this matters because cloudflare workers have a CPU time limit that a persistent socket would otherwise hit. proxying doesn't count as compute.

---

## what we're not building in v1

no ambient always-on screen recording. no persistent memory across sessions. no local search engine over past activity. no second brain features.

v1 is: voice in, action out, fast, shows you what it's doing, covers the top integrations people actually use. get that right first.

---

## the competition

**heyclicky** — closest thing. same concept, further ahead on integrations. built every connector by hand. we're MCP-native from day one which means we scale faster. they're also on an older voice pipeline. we ship GPT-Realtime-2.1 from the start.

**perplexity personal computer** — launched april 2026. more focused on local file access and long-horizon tasks. different angle.

**raycast AI** — keyboard-first, not voice-first. different user.

**apple intelligence** — slow, narrow, won't meaningfully expand before late 2026.

the gap we're going into: GPT-Realtime-2.1 latency + MCP-native integrations + claude code-style live transparency on what's happening + a UI that's actually built for macOS. none of the current players have all of that together.

---

## the codebase

forked from clicky (MIT license). the macOS UI primitives stay — NSPanel, ScreenCaptureKit, CGEvent tap for push-to-talk, OverlayWindow for the notch rendering, the design system tokens. the API layer gets replaced entirely. assemblyAI, elevenlabs, and the claude integration all go. GPT-Realtime-2.1 WebSocket + composio MCP gateway + LMCP local server come in.

the "leanring" typo in the project directory stays. it's legacy. don't rename it.
