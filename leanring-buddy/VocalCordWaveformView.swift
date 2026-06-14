//
//  VocalCordWaveformView.swift
//  leanring-buddy
//
//  A standalone four-bar voice waveform, sized to sit in the notch flank.
//  It is deliberately decoupled from any audio source: the only input is a
//  normalized `level` (0–1), so a caller can drive it from the mic input level
//  or the model's output level interchangeably (wired up in Session C).
//
//  Each bar uses one of the four vocal-cord palette colors (left to right) and
//  fades to black at its base, so the bars read as glowing "cords" rising off a
//  dark surface.
//

import SwiftUI

struct VocalCordWaveformView: View {

    /// Normalized loudness, 0 (silent) to 1 (loud). Clamped internally, so
    /// callers can pass slightly out-of-range values without misbehavior.
    var level: CGFloat

    /// The four bar colors, left to right. Index-aligned with `glowColors` and
    /// `barMultipliers`.
    private let barColors: [Color] = [
        DS.Colors.vocalCordBlue,
        DS.Colors.vocalCordViolet,
        DS.Colors.vocalCordMagenta,
        DS.Colors.vocalCordRose,
    ]

    /// Soft halo color behind each bar (the ~25% palette glow variants).
    private let glowColors: [Color] = [
        DS.Colors.vocalCordBlueGlow,
        DS.Colors.vocalCordVioletGlow,
        DS.Colors.vocalCordMagentaGlow,
        DS.Colors.vocalCordRoseGlow,
    ]

    /// Per-bar height multiplier so the four bars don't move in lockstep — the
    /// outer/odd bars react fully while the others lag slightly, giving the
    /// waveform a more organic, uneven shimmer.
    private let barMultipliers: [CGFloat] = [1.0, 0.8, 1.0, 0.85]

    /// Smallest fraction of the available height a bar shrinks to, so all four
    /// stay visible as little dots even at zero level.
    private let minHeightFraction: CGFloat = 0.14

    var body: some View {
        GeometryReader { geometry in
            // Derive bar width and gap from the available width so the component
            // scales down cleanly to the ~30–40pt notch-flank widths: four bars
            // with three gaps, each gap ~0.6× a bar.
            let barWidth = geometry.size.width / 5.8
            let spacing = (geometry.size.width - barWidth * 4) / 3

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<4, id: \.self) { index in
                    bar(index: index, width: barWidth, fullHeight: geometry.size.height)
                }
            }
            // Anchor the bars to the bottom of the GeometryReader so they grow
            // upward from a shared baseline.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .animation(.easeInOut(duration: 0.1), value: level)
    }

    /// One bar: a vertical-gradient capsule (bright tip → black base) whose
    /// height tracks `level` scaled by this bar's multiplier, with a soft glow.
    private func bar(index: Int, width: CGFloat, fullHeight: CGFloat) -> some View {
        let clampedLevel = max(0, min(1, level))
        let fraction = max(minHeightFraction, clampedLevel * barMultipliers[index])
        let height = fraction * fullHeight

        return RoundedRectangle(cornerRadius: width / 2)
            .fill(
                LinearGradient(
                    colors: [barColors[index], .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width, height: height)
            .shadow(color: glowColors[index], radius: width * 0.7)
    }
}

// MARK: - Preview

/// Drives the waveform from a continuously animated sample level so the preview
/// shows the four bars reacting — no audio source required.
#Preview("Reacting to sample level") {
    TimelineView(.animation) { context in
        let elapsed = context.date.timeIntervalSinceReferenceDate
        // A 0–1 sine sweep stands in for a live loudness signal.
        let sampleLevel = CGFloat((sin(elapsed * 4) + 1) / 2)

        VocalCordWaveformView(level: sampleLevel)
            // Notch-flank dimensions: a small width and ~24–37pt height.
            .frame(width: 36, height: 32)
            .padding(40)
            .background(Color.black)
    }
}

/// Static frames at the height extremes to confirm the bars render correctly
/// across the full notch-flank range.
#Preview("Static levels") {
    HStack(spacing: 24) {
        VocalCordWaveformView(level: 0.0).frame(width: 36, height: 24)
        VocalCordWaveformView(level: 0.5).frame(width: 36, height: 30)
        VocalCordWaveformView(level: 1.0).frame(width: 40, height: 37)
    }
    .padding(40)
    .background(Color.black)
}
