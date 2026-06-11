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
- OverlayWindow.swift, DesignSystem.swift, Analytics.swift, GlobalPushToTalkShortcutMonitor.swift
- BuddyDictationManager.swift (audio wiring is Milestone 3)
- worker/ (done in Milestone 1)

## Done when
- App builds in Xcode (Cmd+R) with no errors
- On launch: WebSocket connects, console logs "session.created received"
- Console logs heartbeat ping every 25s
- registerTool() method exists and compiles correctly
- All deleted files are removed from Xcode project

## If unsure → stop and ask, don't guess
