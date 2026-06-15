//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Push-to-talk microphone capture for the voice pipeline. Captures mic audio
//  with AVAudioEngine, converts it to PCM16 24kHz mono, and streams it to the
//  GPT-Realtime pipeline (RealtimeClient). Also reports an audio power level for
//  the waveform UI. Still owns the shared `BuddyPushToTalkShortcut` shortcut
//  definitions used by the global shortcut monitor.
//

import AppKit
import AVFoundation
import Combine
import Foundation

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let currentShortcutOption: ShortcutOption = .controlOption
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool,
        hotkey: HotkeyConfiguration = .load()
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed,
            hotkey: hotkey
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool,
        hotkey: HotkeyConfiguration
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed,
            hotkey: hotkey
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool,
        hotkey: HotkeyConfiguration
    ) -> ShortcutTransition {
        // Speed only supports modifier-only push-to-talk combos. The shortcut is
        // "pressed" while at least the configured modifiers are held, and matching
        // happens on flagsChanged transitions (keyCode is unused here). Holding
        // extra modifiers still counts as pressed, matching the prior behavior.
        guard shortcutEventType == .flagsChanged else { return .none }

        let isShortcutCurrentlyPressed = modifierFlags.contains(hotkey.modifierFlags)

        if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    /// Shown in the menu-bar panel's status label. The voice pipeline now streams
    /// straight to GPT-Realtime, so there's no separate transcription provider.
    let transcriptionProviderDisplayName = "GPT-Realtime"

    /// True while the mic is actively streaming audio to the realtime pipeline.
    var isDictationInProgress: Bool { realtimePCM16ChunkHandler != nil }

    private let audioEngine = AVAudioEngine()

    /// When set, the mic is streaming PCM16 24kHz mono chunks to RealtimeClient.
    private var realtimePCM16ChunkHandler: ((Data) -> Void)?
    private var realtimeAudioConverter: BuddyPCM16AudioConverter?

    private var lastRecordedAudioPowerSampleDate = Date.distantPast

    // MARK: - Realtime Audio Streaming

    /// Captures microphone audio and forwards it as PCM16 24kHz mono chunks to
    /// `onPCM16Chunk` (for the GPT-Realtime pipeline). Also keeps
    /// `currentAudioPowerLevel` updated so the waveform UI still reacts. Call
    /// `stopRealtimeAudioStreaming()` on key release.
    func startRealtimeAudioStreaming(onPCM16Chunk: @escaping (Data) -> Void) async throws {
        guard realtimePCM16ChunkHandler == nil else { return }

        guard await requestMicrophonePermissionIfNeeded() else {
            lastErrorMessage = "microphone permission is required for push to talk."
            throw NSError(
                domain: "BuddyDictationManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }
        guard !Task.isCancelled else { return }

        isRecordingFromKeyboardShortcut = true
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        lastRecordedAudioPowerSampleDate = .distantPast
        realtimePCM16ChunkHandler = onPCM16Chunk
        // The model expects PCM16 mono 24kHz (Azure Realtime default format).
        let audioConverter = BuddyPCM16AudioConverter(targetSampleRate: 24_000)
        realtimeAudioConverter = audioConverter

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
        realtimePCM16ChunkHandler = nil
        realtimeAudioConverter = nil
        isRecordingFromKeyboardShortcut = false
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

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
