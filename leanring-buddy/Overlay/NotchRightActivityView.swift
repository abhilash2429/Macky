//
//  NotchRightActivityView.swift
//  leanring-buddy
//
//  The right side of Macky's closed notch uses a compact visual vocabulary:
//  input signal, target-safe dictation, model thought, tool work, speech, and
//  attention each have a different glyph without changing the notch footprint.
//

import SwiftUI

enum NotchActivityState: Equatable {
    case idle
    case assistantListening
    case dictationPreflight
    case dictationConnecting
    case dictationListening
    case dictationFinalizing
    case thinking
    case executing
    case speaking
    case failure

    static func resolve(
        voiceState: CompanionVoiceState,
        operationState: AssistantOperationState,
        dictationLifecycle: DictationLifecycle,
        toolCallActive: Bool
    ) -> NotchActivityState {
        switch dictationLifecycle {
        case .preparingTarget:
            return .dictationPreflight
        case .connecting:
            return .dictationConnecting
        case .listening:
            return .dictationListening
        case .finalizing:
            return .dictationFinalizing
        case .idle, .error(_):
            break
        }

        if toolCallActive {
            return .executing
        }

        switch operationState {
        case .listening:
            return .assistantListening
        case .thinking:
            return .thinking
        case .speaking:
            return .speaking
        case .executing(_):
            return .executing
        case .error(_):
            return .failure
        case .idle:
            break
        }

        switch voiceState {
        case .listening:
            return .assistantListening
        case .processing:
            return .thinking
        case .responding:
            return .speaking
        case .idle:
            return .idle
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "Idle"
        case .assistantListening: return "Listening"
        case .dictationPreflight: return "Checking the focused text field"
        case .dictationConnecting: return "Connecting dictation"
        case .dictationListening: return "Dictating"
        case .dictationFinalizing: return "Finalizing dictation"
        case .thinking: return "Thinking"
        case .executing: return "Working"
        case .speaking: return "Speaking"
        case .failure: return "Needs attention"
        }
    }
}

struct NotchRightActivityView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var dictationCoordinator: DictationCoordinator

    private var state: NotchActivityState {
        NotchActivityState.resolve(
            voiceState: companionManager.voiceState,
            operationState: companionManager.operationState,
            dictationLifecycle: dictationCoordinator.lifecycle,
            toolCallActive: companionManager.toolCallActive
        )
    }

    var body: some View {
        Group {
            switch state {
            case .assistantListening, .speaking:
                VoiceActivityView(
                    companionManager: companionManager,
                    realtimeClient: companionManager.realtimeClient
                )
                .frame(width: 24, height: 20)

            case .dictationPreflight:
                DictationPreflightIndicator()

            case .dictationConnecting:
                ConnectionSweepIndicator()

            case .dictationListening:
                HStack(spacing: 2) {
                    Capsule()
                        .fill(.white.opacity(0.78))
                        .frame(width: 2, height: 13)
                    VoiceActivityView(
                        companionManager: companionManager,
                        realtimeClient: companionManager.realtimeClient
                    )
                    .frame(width: 24, height: 20)
                }

            case .dictationFinalizing:
                DictationFinalizingIndicator()

            case .thinking:
                ThinkingPulseIndicator()

            case .executing:
                ExecutionRailIndicator()

            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))

            case .idle:
                Color.clear
            }
        }
        .frame(width: NotchConstants.waveformBoxSize, height: NotchConstants.waveformBoxSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
    }
}

private struct DictationPreflightIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "text.cursor")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))

            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 4, height: 4)
                .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1 : 0.55))
                .opacity(reduceMotion ? 0.8 : (isBreathing ? 0.95 : 0.35))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

private struct ConnectionSweepIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 60 : 0.18)) { context in
            let activeIndex = reduceMotion
                ? 0
                : Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 4
            HStack(spacing: 2.5) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index == activeIndex ? 0.92 : 0.24))
                        .frame(width: 3, height: index == activeIndex ? 15 : 8)
                }
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct DictationFinalizingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 1)
                .frame(width: 19, height: 19)
                .scaleEffect(reduceMotion ? 0.82 : (isPulsing ? 1 : 0.64))
                .opacity(reduceMotion ? 0.6 : (isPulsing ? 0.15 : 0.75))

            Image(systemName: "text.cursor")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.86).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

private struct ThinkingPulseIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.28), lineWidth: 1.25)
                .frame(width: 20, height: 20)
                .scaleEffect(reduceMotion ? 0.82 : (isBreathing ? 1 : 0.58))
                .opacity(reduceMotion ? 0.55 : (isBreathing ? 0.14 : 0.72))

            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 5, height: 5)
                .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1.16 : 0.82))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

private struct ExecutionRailIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 60 : 0.2)) { context in
            let activeIndex = reduceMotion
                ? 1
                : Int(context.date.timeIntervalSinceReferenceDate / 0.2) % 3
            HStack(spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(index == activeIndex ? 0.94 : 0.24))
                        .frame(width: 5, height: index == activeIndex ? 11 : 5)
                }
            }
        }
        .frame(width: 21, height: 20)
    }
}
