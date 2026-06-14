//
//  AurenStatusBar.swift
//  leanring-buddy
//
//  The closed-notch content: a status word on the left, the physical notch gap
//  in the middle, and the voice waveform on the right. Adapted from the Auren
//  fork's AurenStatusBar — it now reads CompanionManager's voiceState (plus the
//  live tool-call narration) instead of AurenManager, and sizes itself from
//  NotchUIModel instead of BoringViewModel.
//
//  Shown only while the assistant is active; when idle the container renders a
//  plain black notch so it blends with the hardware cutout.
//

import SwiftUI

struct AurenStatusBar: View {
    @EnvironmentObject var notch: NotchUIModel
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 0) {
            // LEFT — animated status text. Unlike the original (which boxed the
            // text into a tiny square meant for album art), Speed lets it size to
            // its content so narration like "looking at your screen" reads in full
            // in the menu-bar space to the left of the cutout.
            statusTextView
                .padding(.trailing, 8)
                .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)

            // CENTRE — the physical notch gap, an opaque black bridge
            Rectangle()
                .fill(Color.black)
                .frame(width: max(0, notch.closedNotchSize.width - 20))

            // RIGHT — voice waveform
            HStack {
                VoiceActivityView(
                    companionManager: companionManager,
                    realtimeClient: companionManager.realtimeClient
                )
                .frame(width: 16, height: 12)
            }
            .frame(
                width: max(0, notch.effectiveClosedNotchHeight - 12),
                height: max(0, notch.effectiveClosedNotchHeight - 12),
                alignment: .center
            )
        }
        .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)
    }

    // MARK: - Status text

    /// What the closed bar says. A running tool call's narration ("looking at
    /// your screen") wins; otherwise it reflects the voice state.
    private var displayText: String {
        if companionManager.toolCallActive, let narration = companionManager.narrationText {
            return narration
        }
        switch companionManager.voiceState {
        case .idle:       return ""
        case .listening:  return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking…"
        }
    }

    @ViewBuilder
    private var statusTextView: some View {
        let text = displayText
        ZStack {
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize()
                    .id("status_\(text)")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 4)),
                        removal: .opacity.combined(with: .offset(y: -4))
                    ))
            }
        }
        .animation(.smooth(duration: 0.22), value: text)
        .clipped()
    }
}