//
//  DictationCoordinator.swift
//  leanring-buddy
//
//  Ctrl + Fn dictation is intentionally independent from the realtime assistant:
//  it performs one target-safe realtime text pass and one final insertion, never streams
//  partial text into another app, invokes tools, or produces spoken output.
//

import AppKit
import AVFoundation
import Combine
import Foundation

enum DictationLifecycle: Equatable {
    case idle
    case preparingTarget
    case connecting
    case listening
    case finalizing
    case error(String)
}

@MainActor
final class DictationCoordinator: ObservableObject {
    private static let formattingModeDefaultsKey = "macky.dictation.formattingMode"
    private static let glossaryDefaultsKey = "macky.dictation.glossary"
    // Retain audio captured while the shortcut is held until the on-demand session
    // becomes ready. Ten seconds covers the Worker's connection deadlines without
    // allowing an unhealthy connection to grow memory without bound.
    private static let maximumPreconnectionAudioBytes = 480_000

    @Published private(set) var lifecycle: DictationLifecycle = .idle
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var lastErrorMessage: String?
    @Published var formattingMode: DictationFormattingMode {
        didSet { UserDefaults.standard.set(formattingMode.rawValue, forKey: Self.formattingModeDefaultsKey) }
    }
    @Published var glossaryText: String {
        didSet { UserDefaults.standard.set(glossaryText, forKey: Self.glossaryDefaultsKey) }
    }

    var isActive: Bool {
        switch lifecycle {
        case .idle, .error: return false
        case .preparingTarget, .connecting, .listening, .finalizing: return true
        }
    }

    var statusText: String {
        switch lifecycle {
        case .idle: return ""
        case .preparingTarget: return "Checking field"
        case .connecting: return "Connecting dictation"
        case .listening: return "Dictating"
        case .finalizing: return "Finalizing dictation"
        case .error: return "Dictation needs attention"
        }
    }

    var onFocusedEditPresentation: ((FocusedEditPresentation) -> Void)?

    private let targetIntegration: DictationTargetIntegration
    private let audioCapture: DictationAudioCapture
    private let transcriber: DictationTranscriber

    private var preparedTarget: DictationTargetPreparation?
    private var startTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var bufferedAudioChunks: [Data] = []
    private var bufferedAudioByteCount = 0
    private var capturedAudioByteCount = 0
    private var didDetectAudibleSpeech = false
    private var transcriberReady = false
    private var releaseRequested = false
    private var releaseDate: Date?
    /// Every asynchronous path carries this identifier. Cancelling a dictation
    /// must never let a late socket or audio error alter the next held shortcut.
    private var activeDictationID: UUID?

    init(
        targetIntegration: DictationTargetIntegration,
        audioCapture: DictationAudioCapture,
        transcriber: DictationTranscriber
    ) {
        self.targetIntegration = targetIntegration
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.formattingMode = DictationFormattingMode(
            rawValue: UserDefaults.standard.string(forKey: Self.formattingModeDefaultsKey) ?? ""
        ) ?? .literal
        self.glossaryText = UserDefaults.standard.string(forKey: Self.glossaryDefaultsKey) ?? ""
    }

    convenience init() {
        self.init(
            targetIntegration: DictationTargetIntegration(),
            audioCapture: DictationAudioCapture(),
            transcriber: RealtimeDictationTranscriber()
        )
    }

    func begin() {
        guard lifecycle == .idle else { return }
        let dictationID = UUID()
        activeDictationID = dictationID
        lastErrorMessage = nil
        lifecycle = .preparingTarget
        releaseRequested = false
        releaseDate = nil
        bufferedAudioChunks = []
        bufferedAudioByteCount = 0
        capturedAudioByteCount = 0
        didDetectAudibleSpeech = false
        transcriberReady = false

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let target = try await self.targetIntegration.prepareTarget()
                guard !Task.isCancelled,
                      self.isCurrentDictation(dictationID),
                      self.lifecycle == .preparingTarget else { return }
                self.preparedTarget = target
                try await self.audioCapture.start(
                    onPCM16Chunk: { [weak self] data in
                        DispatchQueue.main.async {
                            guard let self, self.isCurrentDictation(dictationID) else { return }
                            self.handleCapturedAudio(data)
                        }
                    },
                    onAudioPower: { [weak self] power in
                        DispatchQueue.main.async {
                            guard let self, self.isCurrentDictation(dictationID) else { return }
                            self.currentAudioPowerLevel = power
                            if power >= 0.015 { self.didDetectAudibleSpeech = true }
                        }
                    }
                )
                guard !Task.isCancelled, self.isCurrentDictation(dictationID) else { return }
                self.lifecycle = .connecting
                self.openTranscriptionConnection(for: target, dictationID: dictationID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrentDictation(dictationID) else { return }
                self.finishWithError(error.localizedDescription, offerCopyText: nil, dictationID: dictationID)
            }
        }
    }

    func finish() {
        guard lifecycle != .idle else { return }
        guard let dictationID = activeDictationID else {
            cancel()
            return
        }
        releaseRequested = true
        releaseDate = Date()
        _ = audioCapture.stop()
        currentAudioPowerLevel = 0

        if lifecycle == .preparingTarget {
            // No target was validated, so no audio can have started. Cancel before
            // any provider connection is opened.
            cancel()
            return
        }
        guard capturedAudioByteCount > 0, didDetectAudibleSpeech else {
            connectionTask?.cancel()
            transcriber.cancel()
            targetIntegration.discardPreparation()
            finishWithoutInsertion(dictationID: dictationID)
            return
        }
        guard transcriberReady else {
            // Capture has stopped, but audio recorded while Ctrl + Fn was held is
            // still valid. Keep the connection alive so `openTranscriptionConnection`
            // can flush that bounded buffer and commit as soon as the session is ready.
            lifecycle = .finalizing
            return
        }
        finalizeTranscription(dictationID: dictationID)
    }

    func cancel() {
        // Invalidate first so cancellation continuations from this dictation
        // cannot publish an error into a later one.
        activeDictationID = nil
        startTask?.cancel()
        connectionTask?.cancel()
        finalizationTask?.cancel()
        startTask = nil
        connectionTask = nil
        finalizationTask = nil
        _ = audioCapture.stop()
        transcriber.cancel()
        targetIntegration.discardPreparation()
        finishWithoutInsertion()
    }

    private func openTranscriptionConnection(
        for target: DictationTargetPreparation,
        dictationID: UUID
    ) {
        let configuration = DictationTranscriptionConfiguration(
            keyterms: DictationGlossary.keyterms(from: glossaryText),
            surfaceKind: target.surfaceKind,
            formattingMode: formattingMode
        )
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.start(configuration: configuration)
                guard !Task.isCancelled,
                      self.isCurrentDictation(dictationID),
                      self.preparedTarget == target else { return }
                self.transcriberReady = true
                self.flushBufferedAudio()
                if self.releaseRequested {
                    self.finalizeTranscription(dictationID: dictationID)
                } else {
                    self.lifecycle = .listening
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrentDictation(dictationID) else { return }
                self.finishWithError(error.localizedDescription, offerCopyText: nil, dictationID: dictationID)
            }
        }
    }

    private func handleCapturedAudio(_ pcm16Chunk: Data) {
        guard lifecycle == .connecting || lifecycle == .listening || lifecycle == .finalizing else { return }
        guard !pcm16Chunk.isEmpty else { return }
        capturedAudioByteCount += pcm16Chunk.count
        if transcriberReady {
            transcriber.sendAudio(pcm16Chunk)
        } else {
            bufferedAudioChunks.append(pcm16Chunk)
            bufferedAudioByteCount += pcm16Chunk.count
            while bufferedAudioByteCount > Self.maximumPreconnectionAudioBytes,
                  let discarded = bufferedAudioChunks.first {
                bufferedAudioChunks.removeFirst()
                bufferedAudioByteCount -= discarded.count
            }
        }
    }

    private func flushBufferedAudio() {
        for chunk in bufferedAudioChunks {
            transcriber.sendAudio(chunk)
        }
        bufferedAudioChunks = []
        bufferedAudioByteCount = 0
    }

    private func finalizeTranscription(dictationID: UUID) {
        guard finalizationTask == nil, isCurrentDictation(dictationID) else { return }
        lifecycle = .finalizing
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcription = try await self.transcriber.finish()
                guard !Task.isCancelled,
                      self.isCurrentDictation(dictationID),
                      let target = self.preparedTarget else { return }
                try await self.insertFinalTranscription(
                    transcription,
                    into: target,
                    dictationID: dictationID
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrentDictation(dictationID) else { return }
                self.finishWithError(error.localizedDescription, offerCopyText: nil, dictationID: dictationID)
            }
        }
    }

    private func insertFinalTranscription(
        _ transcription: DictationTranscription,
        into target: DictationTargetPreparation,
        dictationID: UUID
    ) async throws {
        guard isCurrentDictation(dictationID) else { return }
        let insertionText = transcription.text
        guard !insertionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishWithError("Macky did not hear text to insert.", offerCopyText: nil, dictationID: dictationID)
            return
        }

        let insertionStartedAt = Date()
        do {
            let presentation = try await targetIntegration.insertFinalText(insertionText)
            guard isCurrentDictation(dictationID) else { return }
            let insertionMilliseconds = Int(Date().timeIntervalSince(insertionStartedAt) * 1_000)
            let totalMilliseconds = releaseDate.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
            MackyAnalytics.dictationOutcome(
                surfaceKind: target.surfaceKind,
                formattingMode: formattingMode,
                outcome: "inserted"
            )
            MackyAnalytics.dictationTiming(
                realtimeFinalizationMilliseconds: transcription.realtimeFinalizationMilliseconds,
                workerConnectionMilliseconds: transcription.workerConnectionMilliseconds,
                insertionMilliseconds: insertionMilliseconds,
                totalMilliseconds: totalMilliseconds
            )
            onFocusedEditPresentation?(presentation)
            finishWithoutInsertion(dictationID: dictationID)
        } catch {
            guard !Task.isCancelled, isCurrentDictation(dictationID) else { return }
            MackyAnalytics.dictationOutcome(
                surfaceKind: target.surfaceKind,
                formattingMode: formattingMode,
                outcome: "copy_offered"
            )
            finishWithError(error.localizedDescription, offerCopyText: insertionText, dictationID: dictationID)
        }
    }

    private func finishWithError(
        _ detail: String,
        offerCopyText: String?,
        dictationID: UUID? = nil
    ) {
        if let dictationID, !isCurrentDictation(dictationID) { return }
        let errorDictationID = activeDictationID
        let presentation: FocusedEditPresentation
        if let offerCopyText, !offerCopyText.isEmpty {
            presentation = FocusedEditPresentation(
                kind: .copyAvailable,
                applicationName: preparedTarget?.applicationName ?? "the previous focused app",
                insertedText: offerCopyText,
                summary: "Dictation is ready to copy",
                detail: "\(detail) Macky did not change the newly focused field.",
                canUndo: false,
                canCopy: true
            )
        } else {
            presentation = FocusedEditPresentation(
                kind: .safetyNotice,
                applicationName: preparedTarget?.applicationName ?? "the focused app",
                summary: "Macky did not type anything",
                detail: detail,
                canUndo: false
            )
        }
        MackyAnalytics.dictationOutcome(
            surfaceKind: preparedTarget?.surfaceKind ?? .generic,
            formattingMode: formattingMode,
            outcome: offerCopyText == nil ? "failed" : "copy_offered"
        )
        onFocusedEditPresentation?(presentation)
        lastErrorMessage = detail
        targetIntegration.discardPreparation()
        transcriber.cancel()
        lifecycle = .error(detail)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  let errorDictationID,
                  self.isCurrentDictation(errorDictationID),
                  case .error = self.lifecycle else { return }
            self.finishWithoutInsertion(dictationID: errorDictationID)
        }
    }

    private func finishWithoutInsertion(dictationID: UUID? = nil) {
        if let dictationID, !isCurrentDictation(dictationID) { return }
        startTask = nil
        connectionTask = nil
        finalizationTask = nil
        preparedTarget = nil
        bufferedAudioChunks = []
        bufferedAudioByteCount = 0
        capturedAudioByteCount = 0
        didDetectAudibleSpeech = false
        transcriberReady = false
        releaseRequested = false
        releaseDate = nil
        currentAudioPowerLevel = 0
        activeDictationID = nil
        lifecycle = .idle
    }

    private func isCurrentDictation(_ dictationID: UUID) -> Bool {
        activeDictationID == dictationID
    }
}

@MainActor
final class RealtimeDictationTranscriber: DictationTranscriber {
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sessionReadyContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<DictationTranscription, Error>?
    private var finalResponseText = ""
    private var workerConnectionStartedAt: Date?
    private var workerConnectionMilliseconds = 0
    private var finalizationStartedAt: Date?
    private var didRequestCommit = false
    private var didReceiveSessionUpdate = false
    private var terminalResult: Result<DictationTranscription, Error>?
    private var audioSendTail: Task<Void, Never>?
    private var acceptsAudio = false

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
    }

    func start(configuration: DictationTranscriptionConfiguration) async throws {
        guard webSocketTask == nil else { throw DictationCoordinatorError.transcriberAlreadyStarted }
        guard let sessionToken = await AuthManager.shared.ensureSessionToken() else {
            throw DictationCoordinatorError.noWorkerSession
        }

        finalResponseText = ""
        workerConnectionMilliseconds = 0
        finalizationStartedAt = nil
        didRequestCommit = false
        didReceiveSessionUpdate = false
        terminalResult = nil
        acceptsAudio = false
        audioSendTail = nil

        var request = URLRequest(url: WorkerEndpoints.dictationRealtimeURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        workerConnectionStartedAt = Date()
        task.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveMessages()
        }

        let startMessage = try JSONSerialization.data(withJSONObject: [
            "type": "dictation.start",
            "keyterms": configuration.keyterms,
            "surface_kind": configuration.surfaceKind.rawValue,
            "formatting_mode": configuration.formattingMode.rawValue,
        ])
        guard let startText = String(data: startMessage, encoding: .utf8) else {
            throw DictationCoordinatorError.invalidWorkerResponse
        }
        try await task.send(.string(startText))
        try await awaitSessionReady()
        acceptsAudio = true
    }

    func sendAudio(_ pcm16Chunk: Data) {
        guard let webSocketTask, acceptsAudio, !didRequestCommit, !pcm16Chunk.isEmpty else { return }
        let audioMessage: String
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "dictation.audio",
                "audio": pcm16Chunk.base64EncodedString(),
            ])
            guard let message = String(data: data, encoding: .utf8) else {
                fail(DictationCoordinatorError.invalidWorkerResponse)
                return
            }
            audioMessage = message
        } catch {
            fail(error)
            return
        }
        let previousTail = audioSendTail
        audioSendTail = Task { [weak self] in
            _ = await previousTail?.value
            // Only chunks captured while Ctrl + Fn was held are queued here. They
            // still need to reach the Worker before the explicit commit, including
            // buffered chunks flushed immediately after a slow connection becomes ready.
            guard let self, !self.didRequestCommit else { return }
            do {
                try await webSocketTask.send(.string(audioMessage))
            } catch {
                self.fail(error)
            }
        }
    }

    func finish() async throws -> DictationTranscription {
        guard let webSocketTask else { throw DictationCoordinatorError.transcriberUnavailable }
        guard !didRequestCommit else { throw DictationCoordinatorError.transcriberAlreadyFinalizing }
        // Stop accepting new capture callbacks before yielding. The serial send
        // tail still flushes work queued while Ctrl + Fn was held.
        acceptsAudio = false
        if let audioSendTail {
            await audioSendTail.value
        }
        didRequestCommit = true
        finalizationStartedAt = Date()
        try await webSocketTask.send(.string("{\"type\":\"dictation.commit\"}"))
        return try await awaitFinalResponse()
    }

    func cancel() {
        acceptsAudio = false
        audioSendTail?.cancel()
        audioSendTail = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sessionReadyContinuation?.resume(throwing: CancellationError())
        finishContinuation?.resume(throwing: CancellationError())
        sessionReadyContinuation = nil
        finishContinuation = nil
        finalResponseText = ""
        didRequestCommit = false
        didReceiveSessionUpdate = false
        terminalResult = .failure(CancellationError())
    }

    private func awaitSessionReady() async throws {
        if didReceiveSessionUpdate { return }
        if let terminalResult {
            _ = try terminalResult.get()
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            sessionReadyContinuation = continuation
        }
    }

    private func awaitFinalResponse() async throws -> DictationTranscription {
        if let terminalResult {
            return try terminalResult.get()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DictationTranscription, Error>) in
            finishContinuation = continuation
        }
    }

    private func receiveMessages() async {
        do {
            while let webSocketTask {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let text): handleProviderMessage(text)
                case .data: continue
                @unknown default: continue
                }
            }
        } catch {
            fail(error)
        }
    }

    private func handleProviderMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else {
            fail(DictationCoordinatorError.invalidWorkerResponse)
            return
        }

        switch type {
        case "session.updated":
            let configuredModel = ((message["session"] as? [String: Any])?["model"] as? String) ?? ""
            guard configuredModel == "gpt-realtime-2.1-mini" else {
                fail(DictationCoordinatorError.unexpectedTranscriptionModel)
                return
            }
            if let workerConnectionStartedAt {
                workerConnectionMilliseconds = Int(Date().timeIntervalSince(workerConnectionStartedAt) * 1_000)
            }
            didReceiveSessionUpdate = true
            sessionReadyContinuation?.resume()
            sessionReadyContinuation = nil

        case "response.output_text.done":
            if let outputText = message["text"] as? String,
               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalResponseText = outputText
            }

        case "response.done":
            guard let response = message["response"] as? [String: Any],
                  response["status"] as? String == "completed" else {
                fail(DictationCoordinatorError.transcriptionFailed)
                return
            }
            let finalText = finalResponseText.isEmpty
                ? outputText(from: response)
                : finalResponseText
            let trimmedFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFinalText.isEmpty else {
                fail(DictationCoordinatorError.emptyTranscription)
                return
            }
            let finalizationMilliseconds = finalizationStartedAt.map {
                Int(Date().timeIntervalSince($0) * 1_000)
            } ?? 0
            let transcription = DictationTranscription(
                text: trimmedFinalText,
                realtimeFinalizationMilliseconds: finalizationMilliseconds,
                workerConnectionMilliseconds: workerConnectionMilliseconds
            )
            terminalResult = .success(transcription)
            acceptsAudio = false
            finishContinuation?.resume(returning: transcription)
            finishContinuation = nil
            receiveTask?.cancel()
            receiveTask = nil
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil

        case "dictation.error", "error":
            fail(DictationCoordinatorError.transcriptionFailed)

        default:
            break
        }
    }

    private func outputText(from response: [String: Any]) -> String {
        let outputItems = response["output"] as? [[String: Any]] ?? []
        return outputItems
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private func fail(_ error: Error) {
        guard terminalResult == nil else { return }
        terminalResult = .failure(error)
        acceptsAudio = false
        audioSendTail?.cancel()
        audioSendTail = nil
        sessionReadyContinuation?.resume(throwing: error)
        finishContinuation?.resume(throwing: error)
        sessionReadyContinuation = nil
        finishContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
}

@MainActor
final class DictationAudioCapture {
    private let audioEngine = AVAudioEngine()
    private var converter: BuddyPCM16AudioConverter?
    private var onPCM16Chunk: ((Data) -> Void)?
    private var onAudioPower: ((CGFloat) -> Void)?

    func start(
        onPCM16Chunk: @escaping (Data) -> Void,
        onAudioPower: @escaping (CGFloat) -> Void
    ) async throws {
        guard self.onPCM16Chunk == nil else { return }
        guard await requestMicrophonePermissionIfNeeded() else {
            throw DictationCoordinatorError.microphonePermissionDenied
        }
        self.onPCM16Chunk = onPCM16Chunk
        self.onAudioPower = onAudioPower
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 24_000)
        self.converter = converter

        let inputNode = audioEngine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Voice processing is best-effort. Some devices/routes reject it;
            // dictation still uses raw mono PCM16 rather than failing capture.
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 800, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let data = converter.convertToPCM16Data(from: buffer), !data.isEmpty {
                self.onPCM16Chunk?(data)
            }
            self.onAudioPower?(Self.audioPower(from: buffer))
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    @discardableResult
    func stop() -> Bool {
        guard onPCM16Chunk != nil else { return false }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        onPCM16Chunk = nil
        onAudioPower = nil
        converter = nil
        return true
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func audioPower(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return min(max(CGFloat(sqrt(sum / Float(buffer.frameLength)) * 10), 0), 1)
    }
}

private enum DictationCoordinatorError: LocalizedError {
    case noWorkerSession
    case invalidWorkerResponse
    case transcriberAlreadyStarted
    case transcriberUnavailable
    case transcriberAlreadyFinalizing
    case unexpectedTranscriptionModel
    case transcriptionFailed
    case emptyTranscription
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .noWorkerSession:
            return "Macky could not start its authenticated dictation session."
        case .invalidWorkerResponse:
            return "The dictation service returned an invalid response."
        case .transcriberAlreadyStarted:
            return "A dictation transcription session is already running."
        case .transcriberUnavailable:
            return "The dictation transcription session did not start."
        case .transcriberAlreadyFinalizing:
            return "Dictation is already finalizing."
        case .unexpectedTranscriptionModel:
            return "The dictation service did not start gpt-realtime-2.1-mini."
        case .transcriptionFailed:
            return "Dictation transcription failed before a final result was available."
        case .emptyTranscription:
            return "Macky did not hear text to insert."
        case .microphonePermissionDenied:
            return "Microphone permission is required for dictation."
        }
    }
}
