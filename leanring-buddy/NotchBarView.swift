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
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var realtimeClient: RealtimeClient
    /// Visible height of the black bar. The hosting panel is taller than this by
    /// the pulse headroom, which stays transparent at rest.
    let barHeight: CGFloat
    /// Reports hover enter/exit so the controller can show/dismiss the drop panel.
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Reports a click so the controller can toggle the drop panel.
    var onTap: () -> Void = {}

    var body: some View {
        ZStack(alignment: .top) {
            // Black background bar. Only this layer pulses on a tool call.
            Color.black
                .clipShape(NotchBarShape())
                .frame(height: barHeight)
                .scaleEffect(y: companionManager.toolCallActive ? 1.15 : 1.0, anchor: .top)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: companionManager.toolCallActive)

            // Content: left status text, empty center over the camera, right viz.
            HStack(spacing: 0) {
                StatusTextView(
                    voiceState: companionManager.voiceState,
                    narrationText: companionManager.narrationText
                )
                Spacer(minLength: 0)
                rightZone
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

    /// Audio visualization routed by voice state. Fixed-width and trailing-aligned
    /// so it hugs the right edge regardless of which indicator is showing.
    @ViewBuilder
    private var rightZone: some View {
        Group {
            switch companionManager.voiceState {
            case .idle:
                EmptyView()
            case .listening:
                WaveformView(audioLevel: companionManager.currentAudioPowerLevel)
            case .processing:
                ThinkingIndicatorView()
            case .responding:
                WaveformView(audioLevel: CGFloat(realtimeClient.playbackAudioLevel))
            }
        }
        .frame(width: 165, alignment: .trailing)
        .animation(.easeInOut(duration: 0.15), value: companionManager.voiceState)
    }
}

/// Left-zone status text. Shows the active tool narration when present, otherwise
/// a word for the current voice state. Empty at idle so the collapsed notch is bare.
struct StatusTextView: View {
    let voiceState: CompanionVoiceState
    let narrationText: String?

    private var displayText: String {
        if let narration = narrationText, !narration.isEmpty {
            return narration
        }
        switch voiceState {
        case .idle:       return ""
        case .listening:  return "listening"
        case .processing: return "thinking"
        case .responding: return "speaking"
        }
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 165, alignment: .leading)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: -4, y: 0)),
                removal: .opacity
            ))
            .animation(.easeInOut(duration: 0.2), value: displayText)
    }
}
