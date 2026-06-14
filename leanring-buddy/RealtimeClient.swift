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

import AVFoundation
import Combine
import Foundation

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
    /// Fired (with the tool name) when a function-call handler starts executing,
    /// and again when it resolves, so the owner can pulse UI for tool activity and
    /// show a narration label. CompanionManager owns `toolCallActive`/`narrationText`.
    var onToolCallStarted: ((String) -> Void)?
    var onToolCallEnded: (() -> Void)?

    /// RMS level (0–1) of the model's voice playback, sampled from the output
    /// mixer. Drives the "speaking" waveform in the notch bar.
    @Published private(set) var playbackAudioLevel: Float = 0

    /// Fired when a full conversation turn finishes (`response.done`), carrying
    /// the transcript of what the user said and what the model replied. The owner
    /// builds the history entry. Either string may be empty if its transcript
    /// didn't arrive in time.
    var onTurnCompleted: ((_ userPhrase: String, _ modelText: String) -> Void)?

    /// Transcript of the current turn's user speech, captured from
    /// `conversation.item.input_audio_transcription.completed`.
    private var pendingUserPhrase = ""
    /// Transcript of the current turn's model speech, captured from the
    /// assistant audio-transcript done event.
    private var pendingModelTranscript = ""

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
    /// True after a barge-in `response.cancel`, until the next response actually
    /// begins. Used to drop late audio deltas from the killed response.
    private var isResponseCancelled = false
    /// Count of audio chunks appended since the last commit (diagnostics).
    private var appendedAudioChunkCount = 0

    /// Deployed Cloudflare Worker /realtime endpoint (Milestone 1 proxy → Azure
    /// GPT-Realtime-2). All traffic routes through here so no key ships in the binary.
    private let workerRealtimeURL = URL(string: "wss://realtime-proxy.speedmac.workers.dev/realtime")!

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
        registerSystemControlTools()
        registerCalendarTools()
        registerRemindersTools()
    }

    // MARK: - Tool Registration

    /// Registers tools owned by the client itself (vs. app-level tools the
    /// owner registers). Done in init so they're included in the first
    /// session.update.
    private func registerBuiltInTools() {
        registerTool(
            name: "get_screen_context",
            description: "Capture and look at the user's screen(s). Call this only when the user refers to something on their screen, asks what they're looking at, or you need to see the screen to help.",
            schema: ["type": "object", "properties": [String: Any]()]
        ) { [weak self] _ in
            guard let self else { return "{\"error\": \"client unavailable\"}" }
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            // Images can't live in a function_call_output, so attach them as a
            // separate user message before the function result is sent.
            self.sendScreenContext(captures)
            return "{\"status\": \"captured\", \"screen_count\": \(captures.count)}"
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

        let task = urlSession.webSocketTask(with: workerRealtimeURL)
        webSocketTask = task
        task.resume()
        print("🔌 RealtimeClient: connecting to \(workerRealtimeURL.absoluteString)")

        startReceiving(on: task)
        startHeartbeat()
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
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
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
        case "response.created":
            // A fresh response has truly started → allow its audio to play.
            hasActiveResponse = true
            isResponseCancelled = false
        case "response.done":
            hasActiveResponse = false
            // A full turn finished: hand the captured transcripts to the owner for
            // the history list, then reset for the next turn.
            onTurnCompleted?(pendingUserPhrase, pendingModelTranscript)
            pendingUserPhrase = ""
            pendingModelTranscript = ""
        // The GA gpt-realtime API documents `response.output_audio.*`, but some
        // deployments still emit the older `response.audio.*` — handle both.
        case "response.audio.delta", "response.output_audio.delta":
            if let base64Audio = json["delta"] as? String {
                handleResponseAudioDelta(base64Audio)
            }
        case "response.audio.done", "response.output_audio.done":
            handleResponseAudioDone()
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
        case "response.function_call_arguments.done":
            dispatchFunctionCall(json)
        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? text
            print("⚠️ RealtimeClient: server error: \(message)")
            lastError = message
        default:
            break
        }
    }

    // MARK: - Session Configuration

    /// Sent immediately after `session.created` to configure the session with
    /// the registered tools. Instructions (system prompt) are added in Milestone 13.
    private func sendSessionUpdate() {
        let tools: [[String: Any]] = registeredTools.values.map { tool in
            [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.schema
            ]
        }

        // GA gpt-realtime session schema: `type` is required, audio formats and
        // turn detection are nested under `audio.input` / `audio.output`. Server
        // VAD is disabled by OMITTING turn_detection — push-to-talk drives commit
        // + response.create manually. Audio is PCM16 24kHz mono in both directions.
        let pcmFormat: [String: Any] = ["type": "audio/pcm", "rate": 24_000]
        sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "tools": tools,
                "tool_choice": "auto",
                "audio": [
                    // Enable input transcription so we receive a text transcript of
                    // the user's speech (drives the drop panel's history). This adds
                    // a transcript channel only — capture/streaming are unchanged.
                    "input": [
                        "format": pcmFormat,
                        "transcription": ["model": "whisper-1"]
                    ],
                    // A voice is required for the model to produce audio output.
                    "output": ["format": pcmFormat, "voice": "alloy"]
                ]
            ]
        ])
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onToolCallStarted?(name)
            let output: String
            do {
                output = try await tool.handler(arguments)
            } catch {
                output = "{\"error\": \"\(error.localizedDescription)\"}"
            }
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
        }
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
    private func sendScreenContext(_ captures: [CompanionScreenCapture]) {
        guard !captures.isEmpty else { return }

        var content: [[String: Any]] = []
        for capture in captures {
            content.append(["type": "input_text", "text": capture.label])
            let base64Image = capture.imageData.base64EncodedString()
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(base64Image)"
            ])
        }

        print("🖼 RealtimeClient: attaching \(captures.count) screen image(s) to conversation")
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ])
    }

    /// Injects user-dropped file context (text and/or images) into the
    /// conversation as a user message, so the model sees it when generating its
    /// next response. Mirrors `sendScreenContext`. Call this before
    /// `requestResponse()`. No-op when there's nothing to send.
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

    // MARK: - Audio Input (mic → model)

    /// Appends a chunk of mic audio to the model's input buffer. `pcm16Data` is
    /// raw little-endian PCM16, 24kHz mono (produced by BuddyPCM16AudioConverter);
    /// the Realtime API expects it base64-encoded.
    func sendAudio(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
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
        sendJSON(["type": "input_audio_buffer.clear"])
    }

    /// Marks the end of the user's utterance (push-to-talk key release).
    func commitAudio() {
        print("📤 RealtimeClient: commit audio (\(appendedAudioChunkCount) chunks)")
        appendedAudioChunkCount = 0
        sendJSON(["type": "input_audio_buffer.commit"])
    }

    /// Asks the model to generate a response to the committed audio.
    func requestResponse() {
        print("📨 RealtimeClient: response.create")
        hasActiveResponse = true
        isResponseCancelled = false
        sendJSON(["type": "response.create"])
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
