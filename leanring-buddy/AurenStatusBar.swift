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
            // FAR LEFT — the persistent animated Macky logo (brand identity), or the
            // active connector's logo while a Composio MCP tool call is running.
            MackyNotchLogo(connector: companionManager.activeConnectorToolCall)
                .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)

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

/// The persistent animated Macky logo shown on the closed notch's left flank.
/// Its padding makes it occupy exactly `NotchConstants.logoFlankWidth`, matching
/// the geometry the host window is sized to.
///
/// While a registered Composio connector's MCP tool call is running, `connector` is
/// non-nil and its bundled logo replaces the animated logo for the call's duration. If
/// the logo asset can't be resolved, it falls through to the animated logo so the chrome
/// never shows a broken image.
struct MackyNotchLogo: View {
    var connector: ConnectorIdentity?

    private var connectorLogo: NSImage? {
        guard let name = connector?.logoAssetName else { return nil }
        return NSImage(named: name)
    }

    var body: some View {
        Group {
            if let connectorLogo {
                let side = NotchConstants.notchLogoWidth
                let corner = side * 0.28
                // Official logo on a white tile (matching the connectors-grid treatment)
                // so dark and multicolor logos stay legible against the black notch.
                Image(nsImage: connectorLogo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.16)
                    .frame(width: side, height: side)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color.white)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                MackyAnimatedLogoView(size: NotchConstants.notchLogoWidth)
            }
        }
        .padding(.leading, NotchConstants.logoLeadingPad)
        .padding(.trailing, NotchConstants.logoTrailingGap)
    }
}

/// The closed-notch content while the assistant is idle: just the opaque black
/// bridge covering the hardware cutout (no logo). Sized to `idleBarMetrics` so the
/// bridge stays centered on the physical notch and clicks pass through elsewhere.
struct NotchIdleBar: View {
    @EnvironmentObject var notch: NotchUIModel

    var body: some View {
        let m = notch.idleBarMetrics
        // Idle is just the opaque black bridge covering the hardware cutout — no
        // logo, so the notch blends with the physical notch when at rest.
        Rectangle()
            .fill(Color.black)
            .frame(width: m.bridgeWidth, height: notch.effectiveClosedNotchHeight)
    }
}
