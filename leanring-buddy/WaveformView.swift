//
//  WaveformView.swift
//  leanring-buddy
//
//  A compact bar-chart audio visualization shown in the notch bar's right zone.
//  Used for both the "listening" state (driven by mic level) and the "speaking"
//  state (driven by model playback level). Each bar's height scales with the
//  incoming level times a fixed per-bar multiplier, so the row has organic
//  variation instead of a flat block.
//

import SwiftUI

struct WaveformView: View {
    /// Current audio level, 0–1. Drives every bar's height.
    let audioLevel: CGFloat

    private let barCount = 14
    private let maxBarHeight: CGFloat = 22
    private let minBarHeight: CGFloat = 3

    /// Pre-generated per-bar multipliers so the bars have different heights at the
    /// same level. Count matches `barCount`.
    private let barMultipliers: [CGFloat] = [
        0.5, 0.8, 0.6, 1.0, 0.7, 0.9, 0.4, 0.85, 0.6, 1.0, 0.7, 0.5, 0.9, 0.6
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let height = max(minBarHeight, audioLevel * maxBarHeight * barMultipliers[index])
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 2, height: height)
                    .animation(.spring(response: 0.12, dampingFraction: 0.6), value: height)
            }
        }
    }
}
