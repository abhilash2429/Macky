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

    /// True between the first audio delta and the matching done event, so we
    /// only fire `onResponseAudioStarted` once per response.
    private var isReceivingResponseAudio = false
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
        // The GA gpt-realtime API documents `response.output_audio.*`, but some
        // deployments still emit the older `response.audio.*` — handle both.
        case "response.audio.delta", "response.output_audio.delta":
            if let base64Audio = json["delta"] as? String {
                handleResponseAudioDelta(base64Audio)
            }
        case "response.audio.done", "response.output_audio.done":
            handleResponseAudioDone()
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
                    "input": ["format": pcmFormat],
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
            let output: String
            do {
                output = try await tool.handler(arguments)
            } catch {
                output = "{\"error\": \"\(error.localizedDescription)\"}"
            }

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
            print("🔊 RealtimeClient: receiving response audio")
            onResponseAudioStarted?()
        }

        guard let buffer = makeFloatBuffer(fromPCM16: pcm16Data) else { return }
        outputPlayerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// The model finished this response's audio.
    private func handleResponseAudioDone() {
        print("✅ RealtimeClient: response audio done")
        isReceivingResponseAudio = false
        // A cancelled response's done event must not flip voiceState to idle —
        // the user has already moved on to a new utterance.
        guard !isResponseCancelled else { return }
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
