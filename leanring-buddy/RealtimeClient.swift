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

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Tool Registration

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
        case "response.audio.delta":
            // TODO(Milestone 3): decode the base64 PCM16 chunk and play via AVAudioEngine.
            break
        case "response.audio.done":
            // TODO(Milestone 3): mark playback complete.
            break
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

        sendJSON([
            "type": "session.update",
            "session": [
                "tools": tools,
                "tool_choice": "auto"
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
