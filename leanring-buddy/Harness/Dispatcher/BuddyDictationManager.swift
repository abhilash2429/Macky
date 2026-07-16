//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Push-to-talk microphone capture for the voice pipeline. Captures mic audio
//  with AVAudioEngine, converts it to PCM16 24kHz mono, and streams it to the
//  GPT-Realtime pipeline (RealtimeClient). Also reports an audio power level for
//  the waveform UI.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0

    /// True while the mic is actively streaming audio to the realtime pipeline.
    var isDictationInProgress: Bool { realtimePCM16ChunkHandler != nil }

    private let audioEngine = AVAudioEngine()

    /// When set, the mic is streaming PCM16 24kHz mono chunks to RealtimeClient.
    private var realtimePCM16ChunkHandler: ((Data) -> Void)?

    // MARK: - Realtime Audio Streaming

    /// Captures microphone audio and forwards it as PCM16 24kHz mono chunks to
    /// `onPCM16Chunk` (for the GPT-Realtime pipeline). Also keeps
    /// `currentAudioPowerLevel` updated so the waveform UI still reacts. Call
    /// `stopRealtimeAudioStreaming()` on key release.
    func startRealtimeAudioStreaming(onPCM16Chunk: @escaping (Data) -> Void) async throws {
        guard realtimePCM16ChunkHandler == nil else { return }

        guard await requestMicrophonePermissionIfNeeded() else {
            throw NSError(
                domain: "BuddyDictationManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }
        guard !Task.isCancelled else { return }

        currentAudioPowerLevel = 0
        realtimePCM16ChunkHandler = onPCM16Chunk
        // The model expects PCM16 mono 24kHz (Azure Realtime default format).
        let audioConverter = BuddyPCM16AudioConverter(targetSampleRate: 24_000)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let pcm16Data = audioConverter.convertToPCM16Data(from: buffer), !pcm16Data.isEmpty {
                self.realtimePCM16ChunkHandler?(pcm16Data)
            }
            self.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        print("🎙️ BuddyDictationManager: realtime audio streaming started")
    }

    /// Stops realtime audio capture started by `startRealtimeAudioStreaming`.
    /// Returns true if capture was actually active — the caller uses this to
    /// avoid committing an empty input buffer on a too-fast press/release.
    @discardableResult
    func stopRealtimeAudioStreaming() -> Bool {
        guard realtimePCM16ChunkHandler != nil else { return false }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        realtimePCM16ChunkHandler = nil
        currentAudioPowerLevel = 0
        print("🎙️ BuddyDictationManager: realtime audio streaming stopped")
        return true
    }

    /// Stops any in-progress capture. Retained for CompanionManager.stop().
    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        stopRealtimeAudioStreaming()
    }

    // MARK: - Audio Power Level (waveform)

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel
        }
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
