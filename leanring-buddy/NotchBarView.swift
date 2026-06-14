//
//  NotchBarView.swift
//  leanring-buddy
//
//  The SwiftUI root hosted inside the notch panel (see NotchPanelController).
//
//  Milestone UI-3: black bar (Mac-notch profile) with a content layer. The bar
//  has three zones: a left status-text zone, an empty center over the camera, and
//  a right audio-visualization zone. Content is driven by CompanionManager's
//  voiceState / level publishers and RealtimeClient's playback level. At idle the
//  state text is empty and the right zone is empty, so the collapsed notch shows
//  nothing but black.
//
//  The bar occupies only `barHeight` and is top-aligned within the panel; the
//  panel keeps a few points of transparent headroom below it for the tool-call
//  pulse (a quick downward stretch-and-snap of the black background only).
//

import Combine
import SwiftUI

/// The notch bar outline: flat top, straight sides, rounded bottom corners.
struct NotchBarShape: Shape {
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Flat top edge, flush against the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Straight right side down to the bottom-right corner arc.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        // Bottom-right rounded corner.
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        // Bottom-left rounded corner.
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

struct NotchBarView: View {
    /// All bar content is driven by this view model, keeping the bar decoupled
    /// from CompanionManager / RealtimeClient (the controller feeds the model).
    @ObservedObject var viewModel: NotchPanelViewModel
    /// Visible height of the black bar. The hosting panel is taller than this by
    /// the pulse headroom, which stays transparent at rest.
    let barHeight: CGFloat
    /// Reports hover enter/exit so the controller can show/dismiss the drop panel.
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Reports a click so the controller can toggle the drop panel.
    var onTap: () -> Void = {}

    /// Braille frames for the tool-call spinner, cycled while a tool runs.
    private let spinnerFrames = ["⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    /// Advances the spinner; only consumed while the spinner is on screen.
    private let spinnerTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var spinnerIndex = 0

    /// True when the bar is showing activity (non-idle). Drives flank reveal.
    private var isActive: Bool { !viewModel.activityText.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            // Center notch fill: the black background bar (unchanged shape/corners).
            // Only this layer pulses on a tool call.
            Color.black
                .clipShape(NotchBarShape())
                .frame(height: barHeight)
                .scaleEffect(y: viewModel.isToolActive ? 1.15 : 1.0, anchor: .top)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: viewModel.isToolActive)

            // Three regions: left flank (text + spinner), center over the camera,
            // right flank (waveform). Both flanks collapse to zero width at idle.
            HStack(spacing: 0) {
                leftFlank
                Spacer(minLength: 0)
                rightFlank
            }
            .padding(.horizontal, 12)
            .frame(height: barHeight)
        }
        // Pin everything to the top of the panel, leaving the headroom below.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Make the whole panel area (including the transparent headroom) hoverable
        // and clickable so the drop panel can be triggered from the bar.
        .contentShape(Rectangle())
        .onHover { onHoverChange($0) }
        .onTapGesture { onTap() }
    }

    /// Left flank: optional braille spinner (while a tool runs) plus the activity
    /// label. Collapses to zero width and fades out at idle.
    private var leftFlank: some View {
        HStack(spacing: 6) {
            if viewModel.isToolActive {
                Text(spinnerFrames[spinnerIndex])
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .onReceive(spinnerTimer) { _ in
                        spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
                    }
            }
            if isActive {
                Text(viewModel.activityText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: isActive ? 160 : 0, alignment: .leading)
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.activityText)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isToolActive)
    }

    /// Right flank: the vocal-cord waveform driven by `waveformLevel`. Collapses
    /// to zero width and fades out at idle.
    private var rightFlank: some View {
        VocalCordWaveformView(level: viewModel.waveformLevel)
            .frame(width: isActive ? 40 : 0, height: barHeight * 0.7)
            .opacity(isActive ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: viewModel.activityText)
    }
}
