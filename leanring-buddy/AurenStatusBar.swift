//
//  AurenStatusBar.swift
//  leanring-buddy
//
//  The closed-notch content: active state text on the left, the physical notch
//  gap in the middle, and the voice waveform on the right.
//
//  Shown only while the assistant is active; when idle the container renders a
//  plain black notch so it blends with the hardware cutout.
//

import SwiftUI

struct AurenStatusBar: View {
    @EnvironmentObject var notch: NotchUIModel
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        // Same geometry the controller used to size the host window, so the
        // content fills it exactly: text left, full-width cutout bridge centred,
        // waveform right. The bar's total width == the window width == m.totalWidth.
        let m = notch.activeBarMetrics(for: companionManager.activeStatusText)
        HStack(spacing: 0) {
            // LEFT — animated status text, capped to m.textWidth so long narration
            // like "looking at your screen" truncates with "…" instead of clipping.
            statusTextView
                .frame(width: m.textWidth, alignment: .leading)
                .padding(.leading, NotchConstants.statusLeadingPad)
                .padding(.trailing, NotchConstants.statusTrailingGap)
                .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)

            // CENTRE — the physical notch gap, an opaque black bridge covering the
            // full hardware cutout (kept centred on screen by the window origin).
            Rectangle()
                .fill(Color.black)
                .frame(width: m.bridgeWidth)

            // RIGHT — voice waveform
            HStack {
                VoiceActivityView(
                    companionManager: companionManager,
                    realtimeClient: companionManager.realtimeClient
                )
                .frame(width: 24, height: 16)
            }
            .frame(
                width: NotchConstants.waveformBoxSize,
                height: NotchConstants.waveformBoxSize,
                alignment: .center
            )
            .padding(.trailing, NotchConstants.waveformTrailingPad)
        }
        .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)
    }

    // MARK: - Status text

    @ViewBuilder
    private var statusTextView: some View {
        // Single source of truth, shared with the window-sizing code so the
        // displayed text and the measured width can never disagree.
        let text = companionManager.activeStatusText
        ZStack {
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
