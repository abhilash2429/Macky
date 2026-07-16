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
    @ObservedObject var dictationCoordinator: DictationCoordinator

    var body: some View {
        // Same geometry the controller used to size the host window, so the
        // content fills it exactly: text left, full-width cutout bridge centred,
        // waveform right. The bar's total width == the window width == m.totalWidth.
        let m = notch.activeBarMetrics(for: companionManager.activeStatusText)
        HStack(spacing: 0) {
            // LEFT — animated status text in a fixed-width slot (no logo). The slot is
            // constant across every state, so long narration like "looking at your
            // screen" truncates with "…" instead of resizing the notch.
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

            // RIGHT — a semantic state glyph. Recording, dictation preparation,
            // model thinking, tool execution, speech, and attention states must
            // not collapse into the same generic spinner.
            NotchRightActivityView(
                companionManager: companionManager,
                dictationCoordinator: dictationCoordinator
            )
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
                    .font(.system(size: DS.Typography.compactStatus, weight: .semibold, design: .rounded))
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

/// A short-lived confirmation that replaces the normal active status bar after
/// Macky changes focused text. It never opens the panel: the tick and optional
/// undo control live on the same closed-notch footprint as live voice status.
struct FocusedEditCompletionBar: View {
    @EnvironmentObject var notch: NotchUIModel
    let presentation: FocusedEditPresentation
    let onUndo: () -> Void
    let onCopy: () -> Void

    private var isFailure: Bool {
        presentation.kind == .safetyNotice
    }

    private var statusText: String {
        switch presentation.kind {
        case .undo:
            return "Restored"
        case .safetyNotice:
            return "Couldn't edit"
        case .copyAvailable:
            return "Ready to copy"
        case .textEdit, .terminalCommand:
            return "Done"
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if presentation.canCopy {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: DS.Typography.compactStatus, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .frame(
                        width: NotchConstants.focusedEditActionButtonSize,
                        height: NotchConstants.focusedEditActionButtonSize
                    )
                    .background(Circle().fill(Color.orange.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Copy dictated text")
            .accessibilityLabel("Copy dictated text")
        } else if presentation.canUndo {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: DS.Typography.compactStatus, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(
                        width: NotchConstants.focusedEditActionButtonSize,
                        height: NotchConstants.focusedEditActionButtonSize
                    )
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Undo last text edit")
            .accessibilityLabel("Undo last text edit")
        } else {
            Image(systemName: passiveAccessorySymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isFailure ? Color.orange.opacity(0.95) : Color.white.opacity(0.72))
                .frame(
                    width: NotchConstants.focusedEditActionButtonSize,
                    height: NotchConstants.focusedEditActionButtonSize
                )
                .background(Circle().fill((isFailure ? Color.orange : Color.white).opacity(0.12)))
                .accessibilityHidden(true)
        }
    }

    private var passiveAccessorySymbol: String {
        switch presentation.kind {
        case .terminalCommand:
            return "terminal"
        case .safetyNotice:
            return "exclamationmark"
        case .textEdit, .undo, .copyAvailable:
            return "checkmark"
        }
    }

    var body: some View {
        let metrics = notch.focusedEditCompletionBarMetrics()
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: isFailure ? "exclamationmark" : "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill((isFailure ? Color.red : Color.green).opacity(0.78)))

                Text(statusText)
                    .font(.system(size: DS.Typography.compactStatus, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.leading, NotchConstants.statusLeadingPad)
            .frame(width: metrics.leftFlankWidth, alignment: .leading)
            .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)

            Rectangle()
                .fill(Color.black)
                .frame(width: metrics.bridgeWidth)

            trailingAccessory
            .frame(width: metrics.rightFlankWidth, height: notch.effectiveClosedNotchHeight, alignment: .leading)
        }
        .frame(height: notch.effectiveClosedNotchHeight, alignment: .center)
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
