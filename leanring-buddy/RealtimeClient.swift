//
//  RealtimeClient.swift
//  leanring-buddy
//
//  Owns the single persistent WebSocket to the GPT-Realtime-2 voice pipeline.
//  The socket connects through the Cloudflare Worker /realtime proxy (which
//  forwards bytes to Azure AI Foundry) on app launch and stays open for the
//  whole session, kept alive by a heartbeat ping every 25 seconds.
//
//  Milestone 2 scope: connection lifecycle, heartbeat, the core Realtime
//  protocol event handling, and function-tool registration. Audio capture and
//  playback are wired in Milestone 3 (the audio.delta/done branches below are
//  intentionally stubbed until then).
//

import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class RealtimeClient: ObservableObject {
    /// Drives UI state in later milestones. Reuses the existing
    /// CompanionVoiceState enum rather than declaring a parallel one.
    @Published private(set) var voiceState: CompanionVoiceState = .idle

    /// The most recent server `error` event message, surfaced for later
    /// milestones to display. Nil until an error arrives.
    @Published private(set) var lastError: String?

    /// Fired when the first audio chunk of a model response arrives, so the
    /// owner can move to the "responding" state. CompanionManager owns voiceState.
    var onResponseAudioStarted: (() -> Void)?
    /// Fired when the model finishes producing audio for a response.
    var onResponseCompleted: (() -> Void)?
    /// Fired when server VAD detects the user has started / stopped speaking. Only
    /// emitted while continuous turn detection is enabled (push-to-talk omits it);
    /// the owner uses them to drive listening/thinking UI in continuous mode.
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    /// Fired (with the tool name) when a function-call handler starts executing,
    /// and again when it resolves, so the owner can pulse UI for tool activity and
    /// show a narration label. CompanionManager owns `toolCallActive`/`narrationText`.
    var onToolCallStarted: ((String) -> Void)?
    var onToolCallEnded: (() -> Void)?
    /// MCP calls are executed by the Realtime service rather than by a local
    /// Swift handler, so they need their own lifecycle callbacks. Without these
    /// the UI can fall back to idle while Composio is still doing work.
    var onMCPCallStarted: ((String) -> Void)?
    var onMCPCallEnded: (() -> Void)?

    /// RMS level (0–1) of the model's voice playback, sampled from the output
    /// mixer. Drives the "speaking" waveform in the notch bar.
    @Published private(set) var playbackAudioLevel: Float = 0

    /// Short verb-phrase shown in the notch's left flank while a tool runs —
    /// the model's own spoken narration (e.g. "opening your slack"), parsed from
    /// `conversation.item.created`. Briefly becomes a "✓ …" confirmation after
    /// the tool's result is sent, then returns to nil. Nil whenever no tool is
    /// running, so the flank falls back to the plain voice-state label.
    @Published private(set) var currentActivity: String?

    /// True while a tool call is in flight (from dispatch through the brief "✓"
    /// confirmation after its result is sent). Drives the left-flank spinner.
    @Published private(set) var isToolActive: Bool = false

    /// Fired when a full conversation turn finishes (`response.done`), carrying
    /// the transcript of what the user said and what the model replied. The owner
    /// builds the history entry. Either string may be empty if its transcript
    /// didn't arrive in time.
    var onTurnCompleted: ((_ userPhrase: String, _ modelText: String) -> Void)?

    /// Fired when a Composio `COMPOSIO_MANAGE_CONNECTIONS` MCP call returns a
    /// Connect Link for a toolkit the user hasn't authorized yet. Carries the
    /// toolkit slug and the OAuth redirect URL; CompanionManager surfaces a
    /// "Connect <App>" row in the notch panel.
    var onConnectionLinkAvailable: ((_ toolkit: String, _ redirectURL: URL) -> Void)?

    /// Local visual guidance hooks. RealtimeClient owns tool dispatch, while the app
    /// coordinator owns AppKit windows and cursor effects so the client stays focused
    /// on realtime protocol concerns.
    var onVisualGuidanceSequenceRequested: (@MainActor (VisualGuidanceSequence) async -> String)?
    var onVisualGuidanceClearRequested: (@MainActor () async -> String)?

    /// Transcript of the current turn's user speech, captured from
    /// `conversation.item.input_audio_transcription.completed`.
    private var pendingUserPhrase = ""
    /// Transcript of the current turn's model speech, captured from the
    /// assistant audio-transcript done event.
    private var pendingModelTranscript = ""

    /// The model's most recent spoken narration, captured from
    /// `conversation.item.created`. Buffered here (rather than shown immediately)
    /// because at creation time we don't yet know whether a tool call follows —
    /// it's promoted to `currentActivity` only when a tool actually dispatches,
    /// and cleared at the end of each response. This keeps plain conversational
    /// replies out of the flank, which only ever shows tool narration.
    private var pendingNarration: String?
    /// Bumped each time a tool call begins so the delayed "✓ …"-then-clear after
    /// one tool can't wipe a newer tool's activity (e.g. chained tool calls).
    private var activityGeneration = 0
    /// Output-item IDs for MCP calls that the service has started and not yet
    /// marked done. Used to keep the notch in an executing state during remote
    /// Composio work, not just after a completed output item arrives.
    private var activeMCPCallIDs = Set<String>()
    /// The single authoritative count of in-flight tool calls — native and MCP
    /// combined. `isToolActive` is derived from this (via `adjustInFlight`), so a
    /// native call starting inside an MCP call's cosmetic-fade window (or vice
    /// versa) can never have the spinner cleared out from under it: the flag only
    /// drops to false when *every* in-flight call, of either kind, has finished.
    private var inFlightCallCount = 0

    /// True between the first audio delta and the matching done event, so we
    /// only fire `onResponseAudioStarted` once per response.
    private var isReceivingResponseAudio = false
    /// Playback buffers scheduled on the player node but not yet finished playing.
    /// `onResponseCompleted` waits for this to reach zero so voiceState stays
    /// "responding" for the whole spoken duration — not just while the server is
    /// streaming audio, which finishes seconds before playback does.
    private var scheduledPlaybackBufferCount = 0
    /// True once the server has sent `response.audio.done` for the current
    /// response (streaming finished). Combined with a drained buffer count, this
    /// is what actually completes the response.
    private var isAudioStreamComplete = false
    /// Bumped at the start of each response's audio and on barge-in. Buffer
    /// completion handlers capture the value at schedule time and ignore
    /// themselves if it no longer matches, so stale handlers from a cancelled or
    /// previous response can't miscount the live one.
    private var playbackGeneration = 0
    /// True while a response is being generated server side (between
    /// `response.created`/our `response.create` and `response.done`). Gates
    /// `response.cancel` so we never cancel when nothing is running.
    private var hasActiveResponse = false
    /// Clears a push-to-talk turn if the server never acknowledges `response.create`.
    /// Without this, a dropped/ignored response request leaves the notch in "Thinking"
    /// and makes the next press send a bogus `response.cancel`.
    private var responseStartTimeoutTask: Task<Void, Never>?
    /// Bumped for each `response.create` so stale timeout tasks from earlier turns no-op.
    private var responseStartGeneration = 0
    /// True after a barge-in `response.cancel`, until the next response actually
    /// begins. Used to drop late audio deltas from the killed response.
    private var isResponseCancelled = false
    /// Count of audio chunks appended since the last commit (diagnostics).
    private var appendedAudioChunkCount = 0
    /// Set when a mic chunk (or the commit) can't be sent because the socket is down
    /// mid-utterance. Surfaced via `lastError` on commit so a reconnect during a
    /// push-to-talk press doesn't silently answer a truncated utterance. Reset at the
    /// start of each capture (`clearAudioBuffer`) and after surfacing.
    private var audioDroppedDuringUtterance = false

    /// When true, the session enables server-side VAD (`turn_detection`) so the
    /// model auto-detects turn boundaries and responds without a manual commit —
    /// this powers continuous-listening mode. Push-to-talk leaves it false and
    /// drives commit + response.create by hand. Toggled via
    /// `setContinuousTurnDetection(_:)`.
    private var continuousTurnDetectionEnabled = false

    /// True while the model's response audio is actively streaming in or still
    /// draining from the player node — i.e. while the speakers are emitting. Used by
    /// continuous mode to gate the mic (half-duplex) so the open mic can't feed
    /// playback back into server VAD. Crucially this is self-clearing: playback
    /// buffers always drain, so it can never leave the mic stuck muted the way a
    /// UI-state flag could if a turn never completes.
    var isPlayingResponseAudio: Bool {
        isReceivingResponseAudio || scheduledPlaybackBufferCount > 0
    }

    /// Deployed Cloudflare Worker /realtime endpoint (proxy → Azure GPT-Realtime-2).
    /// All traffic routes through here so no key ships in the binary. Host derives from
    /// the shared `WorkerEndpoints`.
    private let workerRealtimeURL = WorkerEndpoints.realtimeURL

    /// Deployed Worker route that mints a Composio Tool Router session and returns
    /// `{ url, key }` for the MCP tool entry. Fetched once per session on connect.
    private let composioConfigURL = WorkerEndpoints.composioConfigURL
    /// Cached Composio MCP session URL + project API key for this session, populated
    /// by the one-time `/composio-config` fetch. Nil if the fetch failed/timed out —
    /// in which case the mcp tool entry is simply omitted and local tools still work.
    private var composioMCPURL: String?
    private var composioKey: String?
    /// True once the per-session `/composio-config` fetch has been attempted, so
    /// heartbeat-driven reconnects don't re-fetch (cache or its absence persists).
    private var composioConfigAttempted = false
    /// True once `sendSessionUpdate` has run for the current connection. Lets a
    /// `/composio-config` fetch that resolves *after* the first session.update wire the
    /// MCP tool in with a follow-up update, instead of the config fetch having to block
    /// the socket open. Reset on each (re)connect.
    private var sessionUpdateSent = false

    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?

    /// Runs the async receive loop for the current socket. Cancelled on teardown.
    private var receiveLoopTask: Task<Void, Never>?
    /// Drives the 25s heartbeat cadence. Cancelled on teardown/reconnect.
    private var heartbeatTask: Task<Void, Never>?
    /// True between sending a ping and receiving its pong, used by the 5s watchdog.
    private var isAwaitingPong = false
    /// Increments per ping so stale ping/watchdog callbacks (from before a
    /// reconnect) can be ignored.
    private var pingGeneration = 0
    /// Guards against overlapping reconnect attempts.
    private var isReconnecting = false
    /// True after `disconnect()` so an in-flight receive failure doesn't
    /// trigger an unwanted reconnect during app termination.
    private var isStopped = false

    /// A function tool the model can call. The handler returns a JSON string
    /// that gets sent back as the function_call_output.
    private struct RegisteredTool {
        let name: String
        let description: String
        let schema: [String: Any]
        let handler: ([String: Any]) async throws -> String
    }
    private var registeredTools: [String: RegisteredTool] = [:]

    // MARK: - Audio Output (model voice playback)

    /// Dedicated engine for playing the model's voice. Kept separate from the
    /// mic-capture engine in BuddyDictationManager. Started lazily on first audio.
    private let outputAudioEngine = AVAudioEngine()
    private let outputPlayerNode = AVAudioPlayerNode()
    /// The model streams PCM16 24kHz mono; we play it as Float32 at the same rate.
    private let outputAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var isOutputEngineRunning = false

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
        registerBuiltInTools()
        registerVisualGuidanceTools()
        registerSystemControlTools()
        registerCalendarTools()
        registerRemindersTools()
        registerAppLauncherTool()
    }

    // MARK: - Tool Registration

    /// Registers tools owned by the client itself (vs. app-level tools the
    /// owner registers). Done in init so they're included in the first
    /// session.update.
    private func registerBuiltInTools() {
        registerTool(
            name: "get_screen_context",
            description: "Capture a fresh screenshot when the user asks for help with what is on screen. Default captures the main display so visual guidance coordinates match the teaching overlay. Set all_screens to true only when the user explicitly asks about multiple displays.",
            schema: [
                "type": "object",
                "properties": [
                    "all_screens": [
                        "type": "boolean",
                        "description": "Capture every connected display instead of just the main display. Default false. Only set true when the user explicitly refers to multiple screens."
                    ]
                ]
            ]
        ) { [weak self] arguments in
            guard let self else { return "{\"error\": \"client unavailable\"}" }
            let allScreens = arguments["all_screens"] as? Bool ?? false
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(cursorScreenOnly: false, mainScreenOnly: !allScreens)
            // The screenshot no longer goes to the realtime model. Instead the Worker's
            // vision model turns it into ready-to-play visual-guidance coordinates, and we
            // auto-start that sequence here. The realtime model only narrates.
            return await self.generateAndStartVisualGuidance(from: captures)
        }
    }

    /// Turns a fresh screen capture into a visual-guidance overlay: sends the JPEG to the
    /// Worker's `/canvas-vision` route, decodes the returned sequence, and queues it through
    /// `onVisualGuidanceSequenceRequested` (which presents it in sync with the model's
    /// narration). Returns a short status the realtime model uses to decide what to say.
    private func generateAndStartVisualGuidance(from captures: [CompanionScreenCapture]) async -> String {
        // Prefer the cursor screen; otherwise the first capture (main screen).
        guard let capture = captures.first(where: { $0.isCursorScreen }) ?? captures.first else {
            return "{\"status\": \"visual_guidance_unavailable\", \"error\": \"no screen captured\"}"
        }

        // The vision model targets the user's request. The get_screen_context call can fire
        // before Whisper finishes transcribing, so wait briefly for the transcript, then fall
        // back to an image-only prompt if it never arrives.
        let transcript = await awaitUserTranscript(timeout: 1.5)

        let payload: [String: Any]
        do {
            payload = try await callCanvasVision(
                jpegBase64: capture.imageData.base64EncodedString(),
                transcript: transcript,
                logicalWidth: capture.screenshotWidthInPixels,
                logicalHeight: capture.screenshotHeightInPixels
            )
        } catch {
            print("⚠️ RealtimeClient: canvas-vision request failed: \(error.localizedDescription)")
            return "{\"status\": \"visual_guidance_unavailable\", \"error\": \"vision request failed\"}"
        }

        guard let canvasPayload = payload["canvas_payload"] as? String, !canvasPayload.isEmpty else {
            let reason = (payload["error"] as? String) ?? "no guidance produced"
            print("⚠️ RealtimeClient: canvas-vision returned no payload: \(reason)")
            return "{\"status\": \"visual_guidance_unavailable\", \"error\": \"visual guidance could not be generated; describe the steps verbally instead\"}"
        }

        guard let sequence = try? JSONDecoder().decode(
            VisualGuidanceSequence.self,
            from: Data(canvasPayload.utf8)
        ) else {
            print("⚠️ RealtimeClient: canvas-vision payload did not decode to a sequence")
            return "{\"status\": \"visual_guidance_unavailable\", \"error\": \"visual guidance was malformed; describe the steps verbally instead\"}"
        }

        guard let callback = self.onVisualGuidanceSequenceRequested else {
            return "{\"status\": \"visual_guidance_unavailable\", \"error\": \"visual guidance unavailable\"}"
        }
        // Queues the sequence; it's presented when the model's narration audio starts.
        _ = await callback(sequence)
        return "{\"status\": \"visual guidance ready\", \"guidance_started\": true}"
    }

    /// POSTs the screenshot to the Worker's `/canvas-vision` route and returns the parsed
    /// JSON. Mirrors the existing worker-call pattern (no auth header, like `/spotify-play`).
    private func callCanvasVision(
        jpegBase64: String,
        transcript: String,
        logicalWidth: Int,
        logicalHeight: Int
    ) async throws -> [String: Any] {
        var request = URLRequest(url: WorkerEndpoints.canvasVisionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body: [String: Any] = [
            "jpegBase64": jpegBase64,
            "transcript": transcript,
            "logicalWidth": logicalWidth,
            "logicalHeight": logicalHeight
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Waits up to `timeout` seconds for the current turn's user transcript to arrive, then
    /// returns it (or a generic fallback if it never lands). Polls because the transcript is
    /// set by a separate realtime event on the main actor; awaiting yields so it can process.
    private func awaitUserTranscript(timeout: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingUserPhrase.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        let phrase = pendingUserPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.isEmpty ? "Help the user with what's currently on screen." : phrase
    }

    /// Registers the visual teaching tools used when Macky guides the user through
    /// visible app UI with a full-screen overlay and optional cursor movement.
    private func registerVisualGuidanceTools() {
        // The model no longer builds visual guidance coordinates or drives the cursor.
        // `get_screen_context` captures the screen, the Worker's vision model produces the
        // full sequence (highlights, arrows, labels, and any cursor moves/clicks), and it's
        // played back automatically. The model only narrates. The one tool it still needs is
        // a way to dismiss the overlay when the user asks.
        registerTool(
            name: "clear_visual_guidance",
            description: "Clear Macky's visual teaching overlay. Use when the user says stop, cancel, clear the overlay, or when the guide is no longer relevant.",
            schema: ["type": "object", "properties": [String: Any]()]
        ) { [weak self] _ in
            guard let self else { return "{\"error\": \"client unavailable\"}" }
            guard let callback = self.onVisualGuidanceClearRequested else {
                return "{\"status\": \"cleared\"}"
            }
            return await callback()
        }
    }

    /// Registers the Milestone 8 system-control tools (volume, Do Not Disturb,
    /// lock screen, open URL in Chrome, new Chrome tab). Each handler just
    /// awaits the matching SystemControlsIntegration method; thrown errors are
    /// turned into `{"error": …}` by dispatchFunctionCall. Done in init so they
    /// ride along in the first session.update like the built-in tools.
    private func registerSystemControlTools() {
        let noParams: [String: Any] = ["type": "object", "properties": [String: Any]()]
        // Volume tools accept an optional absolute target so "turn it down to 50
        // percent" sets the volume to exactly 50, while a bare "turn it up" steps by 10.
        let volumeSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "level": [
                    "type": "integer",
                    "description": "Optional target volume as a percentage from 0 to 100. Provide this when the user names a specific level (e.g. \"set volume to 50 percent\"). Omit it for a relative nudge up or down."
                ]
            ]
        ]

        registerTool(
            name: "volume_up",
            description: "Raise the Mac's system output volume. Call when the user asks to turn the volume or sound up, make it louder, or set it to a specific higher percentage.",
            schema: volumeSchema
        ) { arguments in
            try await SystemControlsIntegration.volumeUp(level: Self.intArgument(arguments["level"]))
        }

        registerTool(
            name: "volume_down",
            description: "Lower the Mac's system output volume. Call when the user asks to turn the volume or sound down, make it quieter, or set it to a specific lower percentage.",
            schema: volumeSchema
        ) { arguments in
            try await SystemControlsIntegration.volumeDown(level: Self.intArgument(arguments["level"]))
        }

        registerTool(
            name: "toggle_do_not_disturb",
            description: "Toggle Do Not Disturb / Focus on the Mac. Call when the user asks to turn Do Not Disturb on or off, or silence notifications.",
            schema: noParams
        ) { _ in
            try await SystemControlsIntegration.toggleDoNotDisturb()
        }

        registerTool(
            name: "lock_screen",
            description: "Lock the Mac's screen. Call when the user asks to lock the screen, lock the Mac, or lock the computer.",
            schema: noParams
        ) { _ in
            try await SystemControlsIntegration.lockScreen()
        }

        registerTool(
            name: "open_url_in_chrome",
            description: "Open a web page in Google Chrome. Call when the user asks to open a website or URL in Chrome.",
            schema: [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The full URL or domain to open, e.g. github.com or https://example.com"
                    ]
                ],
                "required": ["url"]
            ]
        ) { arguments in
            guard let urlString = arguments["url"] as? String else {
                return "{\"error\": \"missing url\"}"
            }
            return await SystemControlsIntegration.openURLInChrome(urlString)
        }

        registerTool(
            name: "new_chrome_tab",
            description: "Open a new empty tab in Google Chrome. Call when the user asks to open a new Chrome tab or a new browser tab.",
            schema: noParams
        ) { _ in
            try await SystemControlsIntegration.newChromeTab()
        }

        registerTool(
            name: "control_music",
            description: "Instantly control playback in the user's already-open music app (Spotify or Apple Music). Use for transport: pause, resume/play the current track (when NO specific song is named), skip to the next track, go to the previous track, or report what's currently playing. Prefer this over any connector for these — it's instant. Do NOT use it to start a specific song, album, artist, or playlist by name; use play_spotify_track for that.",
            schema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["play", "pause", "next", "previous", "now_playing"],
                        "description": "play = resume the current track; pause; next = skip forward; previous = go back; now_playing = report the current track and play state."
                    ]
                ],
                "required": ["action"]
            ]
        ) { arguments in
            guard let action = arguments["action"] as? String else {
                return "{\"error\": \"missing action\"}"
            }
            return try await SystemControlsIntegration.controlMusic(action: action)
        }

        registerTool(
            name: "play_spotify_track",
            description: "Play a SPECIFIC song, artist, album, or playlist by name on Spotify. Use this whenever the user names what to play — \"play Blinding Lights\", \"play some Taylor Swift\", \"put on my focus playlist\". It searches Spotify and starts playback in one step (opening the Spotify app if needed), so it's fast and reliable — always prefer it over any Spotify connector for starting playback. Do NOT use control_music for a named song; that only controls whatever is already loaded.",
            schema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "What to play, as spoken — a song title, optionally with the artist, e.g. \"Blinding Lights The Weeknd\" or \"lofi beats\"."
                    ]
                ],
                "required": ["query"]
            ]
        ) { arguments in
            guard let query = arguments["query"] as? String else {
                return "{\"error\": \"missing query\"}"
            }
            return try await SystemControlsIntegration.playSpotifyTrack(query: query)
        }
    }

    /// Registers the Milestone 9 Apple Calendar tools (read a day's events,
    /// create an event, find a free slot), backed by CalendarIntegration's
    /// shared EKEventStore. Thrown errors — including the calendar-permission
    /// message — are turned into `{"error": …}` by dispatchFunctionCall.
    private func registerCalendarTools() {
        registerTool(
            name: "get_calendar_events",
            description: "Read the user's calendar events for a given day. Call when the user asks what's on their schedule or calendar.",
            schema: [
                "type": "object",
                "properties": [
                    "date": [
                        "type": "string",
                        "description": "The day to look up. May be \"today\", \"tomorrow\", \"yesterday\", or an ISO 8601 date like 2026-06-13."
                    ]
                ],
                "required": ["date"]
            ]
        ) { arguments in
            guard let date = arguments["date"] as? String else {
                return "{\"error\": \"missing date\"}"
            }
            return try await CalendarIntegration.getEvents(dateString: date)
        }

        registerTool(
            name: "create_calendar_event",
            description: "Add a new event to the user's calendar. Call when the user asks to schedule, add, or create a meeting or event.",
            schema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "The event's title."
                    ],
                    "startDate": [
                        "type": "string",
                        "description": "Start datetime in ISO 8601, e.g. 2026-06-13T15:00:00."
                    ],
                    "endDate": [
                        "type": "string",
                        "description": "End datetime in ISO 8601, e.g. 2026-06-13T16:00:00."
                    ],
                    "notes": [
                        "type": "string",
                        "description": "Optional notes for the event."
                    ]
                ],
                "required": ["title", "startDate", "endDate"]
            ]
        ) { arguments in
            guard let title = arguments["title"] as? String,
                  let startDate = arguments["startDate"] as? String,
                  let endDate = arguments["endDate"] as? String else {
                return "{\"error\": \"missing title, startDate, or endDate\"}"
            }
            return try await CalendarIntegration.createEvent(
                title: title,
                startDateString: startDate,
                endDateString: endDate,
                notes: arguments["notes"] as? String
            )
        }

        registerTool(
            name: "find_free_slot",
            description: "Find an open time slot of a given length on a day, between 9 AM and 6 PM. Call when the user asks to find free time or when they're available.",
            schema: [
                "type": "object",
                "properties": [
                    "date": [
                        "type": "string",
                        "description": "The day to search. May be \"today\", \"tomorrow\", or an ISO 8601 date like 2026-06-13."
                    ],
                    "durationMinutes": [
                        "type": "integer",
                        "description": "How long the free slot needs to be, in minutes."
                    ]
                ],
                "required": ["date", "durationMinutes"]
            ]
        ) { arguments in
            guard let date = arguments["date"] as? String,
                  let durationMinutes = Self.intArgument(arguments["durationMinutes"]) else {
                return "{\"error\": \"missing date or durationMinutes\"}"
            }
            return try await CalendarIntegration.findFreeSlot(
                dateString: date,
                durationMinutes: durationMinutes
            )
        }
    }

    /// Registers the Milestone 10 Apple Reminders tool. Backed by
    /// RemindersIntegration's own EKEventStore. The thrown permission error is
    /// turned into `{"error": …}` by dispatchFunctionCall.
    private func registerRemindersTools() {
        registerTool(
            name: "create_reminder",
            description: "Add a reminder to the user's Reminders. Call when the user asks to remind them to do something. Include a due date only if the user gives a time.",
            schema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "What to be reminded about."
                    ],
                    "dueDate": [
                        "type": "string",
                        "description": "Optional due datetime in ISO 8601, e.g. 2026-06-14T09:00:00. Omit if the user didn't give a time."
                    ],
                    "notes": [
                        "type": "string",
                        "description": "Optional notes for the reminder."
                    ]
                ],
                "required": ["title"]
            ]
        ) { arguments in
            guard let title = arguments["title"] as? String else {
                return "{\"error\": \"missing title\"}"
            }
            return try await RemindersIntegration.createReminder(
                title: title,
                dueDateString: arguments["dueDate"] as? String,
                notes: arguments["notes"] as? String
            )
        }
    }

    /// Registers the open_app tool, which launches or activates any installed
    /// macOS app by name. Backed by AppLauncherIntegration; an unmatched name
    /// comes back as `{"error": …}` so the model can say it couldn't find the
    /// app rather than going silent.
    private func registerAppLauncherTool() {
        registerTool(
            name: "open_app",
            description: "Launch or activate an installed Mac app by name. Call when the user asks to open, launch, start, or switch to an app, e.g. \"open Reminders\", \"open Safari\", or \"open Visual Studio Code\".",
            schema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "The app's name as the user said it, e.g. \"Reminders\", \"Safari\", or \"Visual Studio Code\"."
                    ]
                ],
                "required": ["name"]
            ]
        ) { arguments in
            guard let name = arguments["name"] as? String else {
                return "{\"error\": \"missing name\"}"
            }
            return try await AppLauncherIntegration.openApp(named: name)
        }
    }

    /// Coerces a decoded JSON tool argument to an Int. The Realtime API's
    /// arguments are parsed by JSONSerialization, so a number can arrive as an
    /// Int, a Double (e.g. `50.0`), or an NSNumber. Returns nil when absent or
    /// non-numeric so callers can fall back to default behavior.
    private static func intArgument(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return nil
    }

    /// Registers a function tool. The schema is the JSON-Schema `parameters`
    /// object the model uses to build arguments. `handler` runs when the model
    /// calls the tool and returns a JSON string sent back as the result.
    func registerTool(
        name: String,
        description: String,
        schema: [String: Any],
        handler: @escaping ([String: Any]) async throws -> String
    ) {
        registeredTools[name] = RegisteredTool(
            name: name,
            description: description,
            schema: schema,
            handler: handler
        )
    }

    // MARK: - Connection Lifecycle

    /// Opens the WebSocket and starts the receive loop + heartbeat. Safe to call
    /// again — any existing connection is torn down first.
    func connect() {
        teardown()
        isStopped = false
        isReconnecting = false
        sessionUpdateSent = false

        // Open the socket immediately and fetch the Composio MCP config *concurrently*
        // rather than awaiting it first — the fetch (up to a 5s timeout) used to add its
        // full latency to every launch before the socket even opened. The socket
        // handshake and the config fetch are independent: `sendSessionUpdate` doesn't run
        // until `session.created` arrives, so the fetch has the whole handshake to
        // finish in parallel. If it resolves first, the MCP entry is in the first
        // session.update; if it resolves later, `fetchComposioConfig` sends a follow-up
        // update (same live mid-session mechanism `setContinuousTurnDetection` uses).
        openSocket()

        // The config fetch runs once per session; heartbeat-driven reconnects skip it,
        // so the cache (or its absence) persists for the session's lifetime.
        if !composioConfigAttempted {
            composioConfigAttempted = true
            Task { @MainActor [weak self] in
                await self?.fetchComposioConfig()
            }
        }
    }

    /// Opens the WebSocket and starts the receive loop + heartbeat. Split out from
    /// `connect()` so the one-time Composio config fetch can run first.
    private func openSocket() {
        let task = urlSession.webSocketTask(with: workerRealtimeURL)
        webSocketTask = task
        task.resume()
        print("🔌 RealtimeClient: connecting to \(workerRealtimeURL.absoluteString)")

        startReceiving(on: task)
        startHeartbeat()
    }

    /// One-time fetch of the Composio Tool Router session config from the Worker.
    /// Short timeout — a slow/unreachable Composio must not block voice. On any
    /// failure the cache stays nil and the session proceeds without the mcp tool.
    private func fetchComposioConfig() async {
        var request = URLRequest(url: composioConfigURL)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let url = json["url"] as? String,
                  let key = json["key"] as? String else {
                print("⚠️ RealtimeClient: composio-config returned no usable config; proceeding without MCP")
                return
            }
            composioMCPURL = url
            composioKey = key
            print("🧩 RealtimeClient: Composio MCP config loaded")
            // If the session was already configured (the socket opened and
            // session.created arrived before this fetch finished), the first
            // session.update went out without the MCP entry — wire it in now with a
            // live follow-up update so connectors still work this session.
            if sessionUpdateSent {
                sendSessionUpdate()
            }
        } catch {
            print("⚠️ RealtimeClient: composio-config fetch failed: \(error); proceeding without MCP")
        }
    }

    /// Closes the connection and stops the heartbeat. Called on app termination.
    func disconnect() {
        isStopped = true
        teardown()
        voiceState = .idle
    }

    /// Cancels the receive loop, heartbeat, and socket. Leaves `isStopped`
    /// untouched so callers decide whether a reconnect should follow.
    private func teardown() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        responseStartTimeoutTask?.cancel()
        responseStartTimeoutTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        // Reset tool-activity state: a disconnect mid-call means the MCP completion
        // event will never arrive, so without this the in-flight count (and the
        // spinner derived from it) would stay stuck across the reconnect. Native
        // calls in flight resolve their own count via their continuation; clearing
        // the MCP set here keeps `inFlightCallCount` and `activeMCPCallIDs` consistent.
        if !activeMCPCallIDs.isEmpty {
            adjustInFlight(-activeMCPCallIDs.count)
            activeMCPCallIDs.removeAll()
        }
    }

    /// Tears down the current connection and reconnects after a short backoff.
    /// No-op if a reconnect is already in flight or we were intentionally stopped.
    private func scheduleReconnect() {
        guard !isStopped, !isReconnecting else { return }
        isReconnecting = true
        teardown()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s backoff
            guard let self, !self.isStopped else { return }
            self.connect()
        }
    }

    // MARK: - Receiving

    /// Awaits frames on `task` until it's torn down or errors. The identity
    /// check ignores late callbacks from a socket we've already replaced.
    private func startReceiving(on task: URLSessionWebSocketTask) {
        receiveLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, self.webSocketTask === task else { return }
                    switch message {
                    case .string(let text):
                        self.handleIncoming(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncoming(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, self.webSocketTask === task else { return }
                    print("⚠️ RealtimeClient: receive failed: \(error)")
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    /// Routes a single Realtime protocol event by its `type`. Does no work
    /// beyond dispatching — no message content is inspected unnecessarily.
    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            print("session.created received")
            sendSessionUpdate()
        case "session.updated":
            print("session.updated received")
        case "response.created":
            // A fresh response has truly started → allow its audio to play.
            responseStartTimeoutTask?.cancel()
            responseStartTimeoutTask = nil
            hasActiveResponse = true
            isResponseCancelled = false
        case "response.done":
            responseStartTimeoutTask?.cancel()
            responseStartTimeoutTask = nil
            hasActiveResponse = false
            // A full turn finished: hand the captured transcripts to the owner for
            // the history list, then reset for the next turn.
            onTurnCompleted?(pendingUserPhrase, pendingModelTranscript)
            pendingUserPhrase = ""
            pendingModelTranscript = ""
            // Drop any buffered narration that no tool consumed (e.g. a plain
            // reply), so it can't be mistaken for a later tool's narration.
            pendingNarration = nil
            settleIfIdle()
        // The GA gpt-realtime API documents `response.output_audio.*`, but some
        // deployments still emit the older `response.audio.*` — handle both.
        case "response.audio.delta", "response.output_audio.delta":
            if let base64Audio = json["delta"] as? String {
                handleResponseAudioDelta(base64Audio)
            }
        case "response.audio.done", "response.output_audio.done":
            handleResponseAudioDone()
        // Server VAD turn boundaries (continuous-listening mode only). On speech
        // start, flush local playback so the model stops talking the instant the
        // user barges in; the server auto-commits and auto-creates the response.
        case "input_audio_buffer.speech_started":
            interruptPlayback()
            onSpeechStarted?()
        case "input_audio_buffer.speech_stopped":
            onSpeechStopped?()
        // Transcript of the user's speech for this turn (input transcription).
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                pendingUserPhrase = transcript
            }
        // Transcript of the model's spoken reply (both event-name variants).
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                pendingModelTranscript = transcript
            }
        // The model's spoken narration (and any assistant message) arrives as a
        // created conversation item. Buffer its text; it's only surfaced if a
        // tool call follows (see dispatchFunctionCall).
        case "conversation.item.created":
            if let narration = assistantText(fromItemCreated: json) {
                pendingNarration = narration
            }
        case "response.function_call_arguments.done":
            dispatchFunctionCall(json)
        // MCP calls execute remotely inside the Realtime service. Track their
        // output-item lifecycle so the notch does not return to idle while a
        // connector action is still running.
        case "response.output_item.added", "response.output_item.created", "response.output_item.in_progress":
            handleMCPOutputItem(json, completed: false)
        // Completed MCP tool calls arrive here with `item.type == "mcp_call"`. When
        // the call is COMPOSIO_MANAGE_CONNECTIONS, its output carries a Connect Link
        // for an unauthorized toolkit, which we surface as a "Connect <App>" row.
        case "response.output_item.done":
            handleMCPOutputItem(json, completed: true)
        case "error":
            responseStartTimeoutTask?.cancel()
            responseStartTimeoutTask = nil
            hasActiveResponse = false
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? text
            print("⚠️ RealtimeClient: server error: \(message)")
            lastError = message
            settleIfIdle()
        default:
            break
        }
    }

    /// Handles a completed output item. Only acts on MCP tool calls
    /// (`item.type == "mcp_call"`): when a COMPOSIO_MANAGE_CONNECTIONS call returns
    /// a Connect Link, parse the toolkit + redirect URL and notify the owner.
    ///
    /// NOTE: the exact `item.output` shape Azure surfaces for the connect-link flow has
    /// not been pinned down against a live Composio session, so `parseConnectionLink`
    /// stays deliberately tolerant of several shapes (JSON string, dict, MCP content
    /// array) with a regex fallback. Keep the defensive parsing until a captured frame
    /// confirms the canonical shape; do not narrow it speculatively.
    private func handleMCPOutputItem(_ json: [String: Any], completed: Bool) {
        guard let item = json["item"] as? [String: Any],
              (item["type"] as? String) == "mcp_call" else {
            return
        }
        let toolName = item["name"] as? String ?? "mcp_call"
        let callID = (item["id"] as? String)
            ?? (item["call_id"] as? String)
            ?? (json["item_id"] as? String)
            ?? toolName

        if completed {
            // The remote action has finished. Drop this MCP call's in-flight count
            // immediately so the notch can settle the moment the turn ends — the "✓"
            // confirmation below is cosmetic and must not gate that. The shared count
            // keeps the spinner up if any other call (MCP or native) is still in
            // flight, closing the race where this cleanup used to flip the flag off
            // while a native call it knew nothing about was still running. Only
            // decrement when this call was actually tracked, to keep the count balanced.
            if activeMCPCallIDs.remove(callID) != nil {
                adjustInFlight(-1)
                onMCPCallEnded?()
                let outputString = item["output"] as? String ?? ""
                MackyAnalytics.toolCall(name: toolName, isMCP: true, success: !outputString.contains("\"error\""))
            }
            activityGeneration += 1
            let generation = activityGeneration
            currentActivity = Self.successPhrase(for: item["output"] as? String ?? "{\"status\":\"done\"}")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, self.activityGeneration == generation else { return }
                self.currentActivity = nil
                self.settleIfIdle()
            }
            settleIfIdle()
        } else if activeMCPCallIDs.insert(callID).inserted {
            activityGeneration += 1
            currentActivity = pendingNarration ?? Self.connectorActivityPhrase(for: toolName)
            pendingNarration = nil
            adjustInFlight(+1)
            onMCPCallStarted?(toolName)
        }

        guard completed, let output = item["output"] else { return }
        guard let (toolkit, url) = parseConnectionLink(fromOutput: output) else { return }
        // Don't log the URL itself — a Composio Connect Link is an authorization redirect
        // and shouldn't land in device logs. Toolkit slug is enough to trace the flow.
        print("RealtimeClient: connect link received for \(toolkit)")
        // Connector-connect funnel step 1: the model surfaced a connect link.
        MackyAnalytics.connectorConnect(step: .linkRequested, toolkit: toolkit)
        onConnectionLinkAvailable?(toolkit, url)
    }

    /// Extracts a (toolkit slug, Connect Link URL) pair from an MCP call's output.
    /// `output` may be a JSON string, a dict, or an MCP content array — we normalize
    /// to a searchable string for the URL and probe likely JSON fields for both.
    private func parseConnectionLink(fromOutput output: Any) -> (toolkit: String, url: URL)? {
        // Normalize the output into (a) a flat text blob and (b) a JSON object if any.
        var text = ""
        var object: [String: Any]?

        if let str = output as? String {
            text = str
            object = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any]
        } else if let dict = output as? [String: Any] {
            object = dict
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                text = s
            }
        } else if let arr = output as? [Any] {
            // MCP content arrays: [{ "type": "text", "text": "..." }, ...]
            for entry in arr {
                if let entryDict = entry as? [String: Any],
                   let t = entryDict["text"] as? String {
                    text += t + "\n"
                }
            }
            if object == nil {
                object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            }
        }

        // Find the redirect URL: prefer explicit JSON fields, fall back to a regex
        // over the text blob for a Composio Connect Link.
        let urlKeys = ["redirect_url", "redirectUrl", "connect_url", "connectUrl", "url"]
        var urlString = object.flatMap { obj in urlKeys.lazy.compactMap { obj[$0] as? String }.first }
        if urlString == nil {
            urlString = Self.firstConnectLink(in: text)
        }
        guard let urlString, let url = URL(string: urlString) else { return nil }

        // Find the toolkit slug from likely JSON fields; fall back to "app".
        let toolkitKeys = ["toolkit", "toolkit_slug", "toolkitSlug", "app", "app_name", "appName"]
        let toolkit = object.flatMap { obj in
            toolkitKeys.lazy.compactMap { obj[$0] as? String }.first
        } ?? "app"

        return (toolkit, url)
    }

    /// Regex-extracts the first Composio Connect Link from arbitrary text.
    private static func firstConnectLink(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "https://connect\\.composio\\.dev/link/[^\\s\"']+"
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    // MARK: - Session Configuration

    /// The session-level system prompt (Azure GPT-Realtime `instructions` field).
    /// Defines Macky's voice-assistant behavior: brief by default, personality for
    /// simple actions, and explicit screen-teaching behavior when the user asks for
    /// visual help. Persists for the whole session.
    private static let mackySystemPrompt = """
        You are Macky, a fast, friendly voice-first macOS personal assistant living in the user's Mac notch. \
        Everything you say is spoken aloud and heard, never read.

        Default mode: answer-first, minimum words. Reply with exactly what the request needs \
        and nothing more. Direct questions get only the answer. "42 plus 60" → "102". \
        "What time is it" → "3:40".

        Simple actions: do the action, then confirm with a short, natural line only if useful. \
        Be lively without being chatty. If the user asks for a rock song, play it and a short \
        "rock on" style response is good. When the effect is obvious, a few words or silence is enough.

        Visual help mode:
        - When the user is stuck in an app, asks for help with "this", asks what to click, or asks to be \
        taught/walked through something visible, immediately call get_screen_context.
        - get_screen_context does everything: it captures the screen and automatically builds and starts the \
        on-screen visual guide (highlights, arrows, labels, and any pointing). You do NOT build coordinates or \
        move the cursor yourself — that is handled for you. Your job is to narrate the steps out loud, clearly \
        and in order, while the overlay plays.
        - When get_screen_context returns guidance_started true, walk the user through the steps in plain spoken \
        language. If it returns visual_guidance_unavailable, tell the user the visual guide couldn't be shown and \
        describe the steps verbally instead.
        - Keep teaching clear and short. One idea per step. Prefer walking through the visual guide over long spoken lists.
        - If the user says stop, cancel, clear the overlay, or never mind, call clear_visual_guidance and stop.

        Tool rules:
        - Music: to start a SPECIFIC song, artist, album, or playlist by name, always use play_spotify_track. \
        For transport on what's already open (pause, resume, skip, previous, "what's playing"), use control_music.
        - Only capture the screen when the user refers to something visual or asks for screen/app help.
        - Never speak raw JSON, code IDs, coordinates, or system internals. Translate results into plain spoken language.
        - When a tool result asks the user to connect or authorize an app, tell them in one short spoken line to finish \
        connecting in the browser window that just opened, then stop.
        - Reply in the same language the user speaks.

        Personality: warm, quick, and competent. Brief for normal tasks; clear and helpful for visual teaching.
        """

    /// The full instructions sent in `session.update`: the static `mackySystemPrompt`
    /// plus the *current* local date and time. Built fresh on every call (including
    /// reconnects, where `sendSessionUpdate` runs again) so the model always has an
    /// accurate "now" to anchor relative dates against — without it, a model that
    /// computes an absolute date for a calendar/reminder instead of saying
    /// "today"/"tomorrow" can silently land on the wrong day with no error surfaced.
    private static func sessionInstructions(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // e.g. "Saturday, 20 June 2026, 3:40 PM PDT"
        formatter.dateFormat = "EEEE, d MMMM yyyy, h:mm a zzz"
        return mackySystemPrompt + "\n\nThe current date and time is \(formatter.string(from: now)). " +
            "Use this as \"now\" when the user refers to relative dates or times like \"today\", " +
            "\"tomorrow\", \"this evening\", or \"next Friday\"."
    }

    /// Sent immediately after `session.created` to configure the session with the
    /// registered tools and the `mackySystemPrompt` system prompt (plus the current
    /// date/time, refreshed each call via `sessionInstructions`).
    private func sendSessionUpdate() {
        var tools: [[String: Any]] = registeredTools.values.map { tool in
            [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.schema
            ]
        }

        // Wire Composio's Tool Router session as an MCP tool — gives the model the
        // full Composio catalog for the connected user. Only added when the
        // one-time /composio-config fetch succeeded; otherwise local tools run alone.
        if let composioMCPURL, let composioKey {
            tools.append([
                "type": "mcp",
                "server_label": "composio",
                "server_url": composioMCPURL,
                "headers": ["x-api-key": composioKey],
                "require_approval": "never"
            ])
        }

        // GA gpt-realtime session schema: `type` is required, audio formats and
        // turn detection are nested under `audio.input` / `audio.output`. In
        // push-to-talk mode `turn_detection` is null so commit + response.create
        // are driven manually. Continuous-listening mode sets it to server VAD so
        // the model auto-detects turns and replies hands-free. Audio is PCM16 24kHz
        // mono in both directions.
        let pcmFormat: [String: Any] = ["type": "audio/pcm", "rate": 24_000]
        // Enable input transcription so we receive a text transcript of the user's
        // speech (drives the drop panel's history). This adds a transcript channel
        // only — capture/streaming are unchanged.
        var inputAudio: [String: Any] = [
            "format": pcmFormat,
            "transcription": ["model": "whisper-1"]
        ]
        if continuousTurnDetectionEnabled {
            inputAudio["turn_detection"] = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
                "create_response": true,
                "interrupt_response": true
            ]
        } else {
            inputAudio["turn_detection"] = NSNull()
        }
        sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": Self.sessionInstructions(),
                "output_modalities": ["audio"],
                "tools": tools,
                "tool_choice": "auto",
                "audio": [
                    "input": inputAudio,
                    // A voice is required for the model to produce audio output.
                    "output": ["format": pcmFormat, "voice": "alloy"]
                ]
            ]
        ])
        sessionUpdateSent = true
    }

    /// Enables or disables server-side VAD (`turn_detection`) for the live session
    /// and re-sends the full `session.update` so the change takes effect mid-session.
    /// Continuous-listening mode turns this on; push-to-talk turns it off.
    ///
    /// The full resend (tools + instructions + MCP entry) is deliberate here, not a
    /// missed optimization: a partial `session.update` carrying only `turn_detection`
    /// would be smaller, but Azure's GA realtime merge semantics for omitting `tools`/
    /// `instructions` and for clearing `turn_detection` (push-to-talk needs it set to
    /// null, not merely omitted) aren't verifiable without a live session — and this
    /// runs only on a manual continuous-listening toggle, never per utterance, so the
    /// extra payload is off the latency-critical path. Kept full to avoid silently
    /// breaking VAD toggling for no user-perceptible gain.
    func setContinuousTurnDetection(_ enabled: Bool) {
        guard continuousTurnDetectionEnabled != enabled else { return }
        continuousTurnDetectionEnabled = enabled
        sendSessionUpdate()
    }

    // MARK: - Tool-activity state

    /// The single writer of `isToolActive`. Both the native-tool path
    /// (`dispatchFunctionCall`) and the MCP path (`handleMCPOutputItem`) route
    /// their start/finish through here so the spinner is governed by one shared
    /// in-flight count rather than two independent rules. `isToolActive` is true
    /// iff at least one call (native or MCP) is in flight, which closes the race
    /// where a stale MCP cleanup flipped the flag off while a native call it knew
    /// nothing about was still running (and the symmetric case).
    private func adjustInFlight(_ delta: Int) {
        inFlightCallCount = max(0, inFlightCallCount + delta)
        isToolActive = inFlightCallCount > 0
    }

    // MARK: - Function Calling

    /// Runs the handler for a completed function call, then sends the result
    /// back as a function_call_output and asks the model to continue.
    private func dispatchFunctionCall(_ json: [String: Any]) {
        guard let name = json["name"] as? String,
              let callID = json["call_id"] as? String else {
            return
        }
        print("🛠 RealtimeClient: function call → \(name)")
        guard let tool = registeredTools[name] else {
            print("⚠️ RealtimeClient: no handler registered for tool \(name)")
            return
        }

        let argumentsString = json["arguments"] as? String ?? "{}"
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsString.utf8))) as? [String: Any] ?? [:]

        // A tool is now confirmed running: surface the model's buffered narration
        // (if any) and raise the spinner. The generation guards the delayed clear
        // below against a newer chained tool call taking over in the meantime.
        activityGeneration += 1
        let generation = activityGeneration
        currentActivity = pendingNarration
        pendingNarration = nil
        adjustInFlight(+1)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onToolCallStarted?(name)
            let output: String
            var didThrow = false
            do {
                output = try await tool.handler(arguments)
            } catch {
                output = "{\"error\": \"\(error.localizedDescription)\"}"
                didThrow = true
            }
            // Success = the handler returned without throwing and its output isn't an
            // {"error": …} payload (handlers report soft failures that way too).
            let succeeded = !didThrow && !output.contains("\"error\"")
            MackyAnalytics.toolCall(name: name, isMCP: false, success: succeeded)
            self.onToolCallEnded?()

            self.sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ]
            ])
            self.hasActiveResponse = true
            self.isResponseCancelled = false
            self.sendJSON(["type": "response.create"])

            // The handler is done and the follow-up response is requested. Drop this
            // call's in-flight count now (the model's spoken reply, if any, drives the
            // notch from here) so a short turn can't end while we're still flagged busy
            // and leave the notch stuck. The shared count keeps the spinner up if any
            // other call (native or MCP) is still running. Briefly show a "✓ …"
            // confirmation — cosmetic, it does not gate settling — unless a newer tool
            // call has taken over (guarded by the generation).
            self.adjustInFlight(-1)
            guard self.activityGeneration == generation else { return }
            self.currentActivity = Self.successPhrase(for: output)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.activityGeneration == generation else { return }
            self.currentActivity = nil
            self.settleIfIdle()
        }
    }

    /// Extracts the assistant's text from a `conversation.item.created` event,
    /// or nil for non-assistant items / items with no text yet. Spoken narration
    /// arrives as an audio part's `transcript`; typed text arrives as `text`.
    /// Field names mirror the GA schema's nested `item.content[]` shape, parsed in
    /// the same defensive style as the top-level `transcript`/`name` keys above.
    private func assistantText(fromItemCreated json: [String: Any]) -> String? {
        guard let item = json["item"] as? [String: Any],
              (item["role"] as? String) == "assistant",
              let content = item["content"] as? [[String: Any]] else {
            return nil
        }
        for part in content {
            if let transcript = part["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcript
            }
            if let text = part["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// A short, human progress phrase for the notch while a connector's MCP tool
    /// runs — "Searching Spotify", "Playing on Spotify", "Sending email" — instead
    /// of a frozen "using connector". Derived from the Composio tool name, which is
    /// UPPER_SNAKE and prefixed with the toolkit (`SPOTIFY_START_RESUME_PLAYBACK`,
    /// `GMAIL_SEND_EMAIL`). Notch-only: it is never spoken (the system prompt keeps
    /// the model silent while tools run). Because each MCP call emits its own
    /// phrase, a multi-step action shows real progress ("Searching Spotify" →
    /// "Playing on Spotify").
    private static func connectorActivityPhrase(for toolName: String) -> String {
        let upper = toolName.uppercased()
        // COMPOSIO_MANAGE_CONNECTIONS (and other meta tools) belong to no toolkit.
        if upper.hasPrefix("COMPOSIO") { return "Connecting" }

        // Toolkit display name from the registry when known (Spotify, Gmail, …),
        // else the leading token title-cased (e.g. "Github" from GITHUB_…).
        let toolkit = ConnectorRegistry.match(toolName: toolName)?.displayName
            ?? toolName.split(separator: "_").first.map { $0.capitalized }
            ?? "connector"

        func has(_ keyword: String) -> Bool { upper.contains(keyword) }
        // Order matters: "PLAY" is a substring of PLAYLIST/PLAYBACK/PLAYING, so the
        // specific verbs (and the read/write verbs) are checked before the bare
        // "PLAY" fallback — otherwise CREATE_PLAYLIST or GET_CURRENTLY_PLAYING would
        // read "Playing on …".
        if has("PREVIOUS") { return "Going back" }
        if has("NEXT") || has("SKIP") { return "Skipping track" }
        if has("PAUSE") || has("STOP") { return "Pausing \(toolkit)" }
        if has("SEARCH") { return "Searching \(toolkit)" }
        if has("SEND") { return "Sending \(toolkit == "Gmail" ? "email" : "message")" }
        if has("CREATE") || has("ADD") || has("INSERT") || has("UPDATE") || has("EDIT")
            || has("DELETE") || has("REMOVE") { return "Updating \(toolkit)" }
        if has("GET") || has("FETCH") || has("LIST") || has("FIND") || has("READ") {
            return "Checking \(toolkit)"
        }
        if has("RESUME") || has("PLAY") || has("START") { return "Playing on \(toolkit)" }
        return "Using \(toolkit)"
    }

    /// Builds the brief confirmation phrase shown after a tool result is sent.
    /// Uses the handler output's `status` (e.g. "opened") when present, otherwise
    /// a generic "✓ done".
    private static func successPhrase(for output: String) -> String {
        if let data = output.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let status = json["status"] as? String,
           !status.isEmpty {
            return "✓ \(status)"
        }
        return "✓ done"
    }

    // MARK: - Sending

    private func sendJSON(_ payload: [String: Any]) {
        guard let task = webSocketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            print("⚠️ RealtimeClient: failed to serialize outgoing payload")
            return
        }
        // Uses the completion-handler send (not async) on purpose: URLSession
        // queues these in call order, which preserves frame ordering for
        // sequences like function_call_output → response.create. Separate
        // awaited Tasks could interleave and reorder them.
        task.send(.string(string)) { error in
            if let error {
                print("⚠️ RealtimeClient: send failed: \(error)")
            }
        }
    }

    /// Adds the captured screens to the conversation as a user message with
    /// input_image content. The Realtime API can't carry images inside a
    /// function_call_output, so the get_screen_context handler attaches them
    /// here; the model then sees them when it generates its response.
    /// Injects user-dropped file context (text and/or images) into the
    /// conversation as a user message, so the model sees it when generating its
    /// next response. Call this before `requestResponse()`. No-op when there's
    /// nothing to send.
    func sendUserContext(texts: [String], images: [Data]) {
        guard !texts.isEmpty || !images.isEmpty else { return }

        var content: [[String: Any]] = []
        for text in texts where !text.isEmpty {
            content.append(["type": "input_text", "text": text])
        }
        for imageData in images {
            let base64Image = imageData.base64EncodedString()
            content.append([
                "type": "input_image",
                "image_url": "data:image/png;base64,\(base64Image)"
            ])
        }
        guard !content.isEmpty else { return }

        print("📎 RealtimeClient: attaching \(texts.count) text + \(images.count) image context item(s)")
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ])
    }

    /// Attaches files dropped on the notch drop zone as a user message, read and
    /// classified by type: images become `input_image` (PNG, base64, same data-URL
    /// pattern as `sendUserContext`), UTF-8-readable files become `input_text` with
    /// their contents, and anything else becomes `input_text` naming the file path
    /// so the model at least knows it was attached. Call before `requestResponse()`.
    func sendDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var content: [[String: Any]] = []
        for url in urls {
            let name = url.lastPathComponent
            let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)

            if let contentType, contentType.conforms(to: .image), let base64 = Self.pngBase64(forImageAt: url) {
                content.append([
                    "type": "input_image",
                    "image_url": "data:image/png;base64,\(base64)"
                ])
            } else if let text = Self.readableText(at: url) {
                content.append(["type": "input_text", "text": "Attached file \"\(name)\":\n\(text)"])
            } else {
                // Unreadable/binary (e.g. PDF, archives): give the model the path
                // as context rather than dropping the attachment silently.
                content.append(["type": "input_text", "text": "Attached file: \(url.path)"])
            }
        }
        guard !content.isEmpty else { return }

        print("📎 RealtimeClient: attaching \(urls.count) dropped file(s)")
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ])
    }

    /// Re-encodes the image at `url` to base64 PNG, or nil if it isn't a readable
    /// image. PNG keeps the injected data-URL format predictable.
    private static func pngBase64(forImageAt url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png.base64EncodedString()
    }

    /// Reads `url` as UTF-8 text, or nil if it isn't valid UTF-8 (e.g. a binary
    /// file) or is empty.
    private static func readableText(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - Audio Input (mic → model)

    /// Appends a chunk of mic audio to the model's input buffer. `pcm16Data` is
    /// raw little-endian PCM16, 24kHz mono (produced by BuddyPCM16AudioConverter);
    /// the Realtime API expects it base64-encoded.
    func sendAudio(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        // If the socket is down mid-utterance (a reconnect is in flight), this chunk
        // can't reach the server. We deliberately do NOT buffer-and-replay: the
        // reconnect clears the server-side input buffer, so replaying only part of an
        // utterance would commit a fragment that transcribes wrong. Instead, flag that
        // the utterance lost audio so `commitAudio` can surface it rather than silently
        // committing a partial turn.
        if webSocketTask == nil {
            audioDroppedDuringUtterance = true
            return
        }
        if appendedAudioChunkCount == 0 {
            print("📤 RealtimeClient: sending first audio chunk (\(pcm16Data.count) bytes)")
        }
        appendedAudioChunkCount += 1
        sendJSON([
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString()
        ])
    }

    /// Discards any uncommitted audio in the model's input buffer. Sent at the
    /// start of a new push-to-talk capture so leftover audio from a prior press
    /// can't be committed with the new utterance.
    func clearAudioBuffer() {
        appendedAudioChunkCount = 0
        audioDroppedDuringUtterance = false
        sendJSON(["type": "input_audio_buffer.clear"])
    }

    /// Marks the end of the user's utterance (push-to-talk key release).
    func commitAudio() -> Bool {
        // A reconnect mid-utterance dropped chunks (and cleared the server buffer), so
        // the committed audio would be incomplete. Surface it instead of committing a
        // partial turn the user would hear get answered wrong, and skip the commit.
        if audioDroppedDuringUtterance || webSocketTask == nil {
            print("⚠️ RealtimeClient: audio dropped during reconnect — not committing partial utterance")
            lastError = "Lost connection while you were talking — try again."
            audioDroppedDuringUtterance = false
            appendedAudioChunkCount = 0
            return false
        }
        guard appendedAudioChunkCount > 0 else {
            print("⚠️ RealtimeClient: commit skipped — no audio chunks captured")
            lastError = "I didn't catch any audio — try holding the shortcut a little longer."
            return false
        }
        print("📤 RealtimeClient: commit audio (\(appendedAudioChunkCount) chunks)")
        appendedAudioChunkCount = 0
        sendJSON(["type": "input_audio_buffer.commit"])
        return true
    }

    /// Asks the model to generate a response to the committed audio.
    func requestResponse() {
        print("📨 RealtimeClient: response.create")
        isResponseCancelled = false
        sendJSON(["type": "response.create"])
        scheduleResponseStartTimeout()
    }

    private func scheduleResponseStartTimeout() {
        responseStartGeneration += 1
        let generation = responseStartGeneration
        responseStartTimeoutTask?.cancel()
        responseStartTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self,
                  self.responseStartGeneration == generation,
                  !self.hasActiveResponse else { return }
            print("⚠️ RealtimeClient: response.create timed out before response.created")
            self.lastError = "The realtime service didn't start a response — try again."
            self.settleIfIdle()
        }
    }

    // MARK: - Audio Output (model voice → speakers)

    /// Lazily starts the playback engine. Returns false if it couldn't start.
    private func startOutputEngineIfNeeded() -> Bool {
        guard !isOutputEngineRunning else { return true }

        outputAudioEngine.attach(outputPlayerNode)
        outputAudioEngine.connect(
            outputPlayerNode,
            to: outputAudioEngine.mainMixerNode,
            format: outputAudioFormat
        )
        installPlaybackLevelTap()
        outputAudioEngine.prepare()

        do {
            try outputAudioEngine.start()
            outputPlayerNode.play()
            isOutputEngineRunning = true
            return true
        } catch {
            print("⚠️ RealtimeClient: failed to start output audio engine: \(error)")
            return false
        }
    }

    /// Installs a tap on the output mixer that publishes the playback RMS level
    /// (0–1) for the "speaking" waveform. Installed once with the engine; while no
    /// audio is playing the tap reports ~0, so the level decays to silence on its
    /// own. The RMS math mirrors BuddyDictationManager's mic level for a matching
    /// visual response.
    private func installPlaybackLevelTap() {
        let mixer = outputAudioEngine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            let samples = channelData[0]
            var summedSquares: Float = 0
            for sampleIndex in 0..<frameCount {
                let sample = samples[sampleIndex]
                summedSquares += sample * sample
            }
            let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
            let boostedLevel = min(max(rootMeanSquare * 8, 0), 1)

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Fast attack, slow release so the bars feel lively but don't flicker.
                self.playbackAudioLevel = max(boostedLevel, self.playbackAudioLevel * 0.7)
            }
        }
    }

    /// Decodes a base64 PCM16 chunk and schedules it for playback. The first
    /// chunk of a response also flips the owner into the "responding" state.
    private func handleResponseAudioDelta(_ base64Audio: String) {
        // After a barge-in cancel, ignore audio still in flight for the old
        // response so it can't resume on the re-armed player node.
        guard !isResponseCancelled else { return }
        guard let pcm16Data = Data(base64Encoded: base64Audio), !pcm16Data.isEmpty else { return }
        guard startOutputEngineIfNeeded() else { return }

        if !isReceivingResponseAudio {
            isReceivingResponseAudio = true
            // Start a fresh playback session for this response.
            playbackGeneration += 1
            scheduledPlaybackBufferCount = 0
            isAudioStreamComplete = false
            print("🔊 RealtimeClient: receiving response audio")
            onResponseAudioStarted?()
        }

        guard let buffer = makeFloatBuffer(fromPCM16: pcm16Data) else { return }
        let generation = playbackGeneration
        scheduledPlaybackBufferCount += 1
        // The completion handler fires (off the main thread) when this buffer has
        // finished playing — that's the real end of audio, not the stream's end.
        outputPlayerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration else { return }
                self.scheduledPlaybackBufferCount -= 1
                self.completeResponseIfPlaybackDrained()
            }
        }
    }

    /// The server finished STREAMING this response's audio. Playback of the
    /// already-scheduled buffers usually continues for several more seconds, so we
    /// don't complete the response here — we mark the stream done and let the last
    /// buffer's playback finish the response.
    private func handleResponseAudioDone() {
        print("✅ RealtimeClient: response audio streaming done")
        isReceivingResponseAudio = false
        // A cancelled response's done event must not flip voiceState to idle —
        // the user has already moved on to a new utterance.
        guard !isResponseCancelled else { return }
        isAudioStreamComplete = true
        completeResponseIfPlaybackDrained()
    }

    /// Fires `onResponseCompleted` only once the server has finished streaming AND
    /// every scheduled buffer has finished playing — i.e. the model is truly done
    /// talking. Called from both the stream-done event and each buffer's playback
    /// completion, whichever happens last.
    private func completeResponseIfPlaybackDrained() {
        guard isAudioStreamComplete, scheduledPlaybackBufferCount == 0 else { return }
        isAudioStreamComplete = false
        playbackAudioLevel = 0
        settleIfIdle()
    }

    /// Returns the notch to rest once nothing is in flight: no active response, no
    /// audio streaming or queued, no local tool running, no MCP call running. Called
    /// from every completion edge (`response.done`, playback drained, tool/MCP
    /// finished) so a lingering "✓" confirmation can no longer strand the notch on
    /// "Thinking"/"Executing". No-ops while any work remains, so it is safe to call
    /// speculatively.
    private func settleIfIdle() {
        guard !hasActiveResponse,
              !isReceivingResponseAudio,
              scheduledPlaybackBufferCount == 0,
              !isToolActive,
              activeMCPCallIDs.isEmpty else { return }
        onResponseCompleted?()
    }

    /// Stops playback immediately and clears the queue — used for barge-in when
    /// the user starts a new utterance while the model is still talking.
    func interruptPlayback() {
        // Stop the server from generating the rest of the current response;
        // otherwise its in-flight audio deltas would just re-fill the player.
        if hasActiveResponse {
            print("✋ RealtimeClient: barge-in → response.cancel")
            sendJSON(["type": "response.cancel"])
            hasActiveResponse = false
        }
        responseStartTimeoutTask?.cancel()
        responseStartTimeoutTask = nil
        // Drop any deltas still arriving for the cancelled response.
        isResponseCancelled = true

        guard isOutputEngineRunning else { return }
        outputPlayerNode.stop()
        outputPlayerNode.play() // re-arm so the next response can schedule buffers
        isReceivingResponseAudio = false
        // Invalidate the cancelled response's playback session: bump the
        // generation so its buffer completion handlers no-op, and reset the
        // counters so the next response starts clean.
        playbackGeneration += 1
        scheduledPlaybackBufferCount = 0
        isAudioStreamComplete = false
    }

    /// Converts raw little-endian PCM16 mono into a Float32 buffer the player
    /// node can schedule. Manual (`Int16 / 32768`) conversion avoids the
    /// off-limits BuddyAudioConversionSupport (which only converts *to* PCM16).
    private func makeFloatBuffer(fromPCM16 pcm16Data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: outputAudioFormat,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        pcm16Data.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for sampleIndex in 0..<sampleCount {
                channel[sampleIndex] = Float(Int16(littleEndian: int16Samples[sampleIndex])) / 32768.0
            }
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        return buffer
    }

    // MARK: - Heartbeat

    /// Sends a ping every 25 seconds to keep the connection alive.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                self?.sendHeartbeatPing()
            }
        }
    }

    /// Sends one ping and arms a 5s watchdog. If the pong doesn't return in
    /// time (or the ping errors), the connection is rebuilt.
    private func sendHeartbeatPing() {
        guard let task = webSocketTask else { return }
        print("heartbeat ping")

        pingGeneration += 1
        let generation = pingGeneration
        isAwaitingPong = true

        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.pingGeneration == generation else { return }
                self.isAwaitingPong = false
                if let error {
                    print("⚠️ RealtimeClient: heartbeat ping failed: \(error)")
                    self.scheduleReconnect()
                }
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.pingGeneration == generation, self.isAwaitingPong else { return }
            print("⚠️ RealtimeClient: pong timeout, reconnecting")
            self.scheduleReconnect()
        }
    }
}
