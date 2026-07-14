//
//  NotchUIModel.swift
//  leanring-buddy
//
//  The Macky-native replacement for BoringNotch's BoringViewModel — but trimmed
//  to only what Macky's notch views read. It owns two things:
//
//    1. The open/closed state (`notchState`) and the sizes the SwiftUI layout
//       interpolates between (`closedNotchSize` / `notchSize`).
//    2. open()/close(), which flip the state with the same spring feel as the
//       original. NotchPanelController observes `notchState` to resize the host
//       NSPanel frame (small when closed so clicks pass through, full when open).
//
//  Deliberately NOT a singleton and NOT a second voice state machine: voice
//  state still lives in CompanionManager. This model is purely about geometry
//  and whether the panel is expanded.
//

import AppKit
import Combine
import SwiftUI

/// Fixed geometry constants, mirroring BoringNotch's `sizing/matters.swift`.
enum NotchConstants {
    /// The expanded panel's content size. Width is unchanged. Height was originally
    /// reduced from 420 to 280 to keep the panel short; bumped to 340 for the
    /// horizon redesign so the single-column Connectors list and the fully
    /// scrollable Settings page can show more content before scrolling further.
    /// This height is shared by every open-panel page (Home, Connectors, Settings,
    /// Files, Auth, Onboarding) — there is only one open panel size.
    static let openNotchSize = CGSize(width: 680, height: 340)
    /// Transparent breathing room around the panel so the drop shadow isn't clipped.
    static let shadowPadding: CGFloat = 20
    /// Total host-window size when open (content + shadow padding).
    static let windowSize = CGSize(
        width: openNotchSize.width,
        height: openNotchSize.height + shadowPadding
    )
    /// Corner radii for the NotchShape in each state: (top, bottom).
    static let openedCornerRadius: (top: CGFloat, bottom: CGFloat) = (top: 22, bottom: 28)
    static let closedCornerRadius: (top: CGFloat, bottom: CGFloat) = (top: 10, bottom: 18)
    /// Fallback notch width when the screen's menu-bar auxiliary areas misreport.
    static let fallbackNotchWidth: CGFloat = 185
    /// Width of the floating bar on displays that have no physical notch.
    static let nonNotchBarWidth: CGFloat = 220

    // MARK: - Active closed-bar layout

    /// Leading inset for the status text so it clears the shape's rounded corner.
    static let statusLeadingPad: CGFloat = 18
    /// Gap between the status text and the cutout bridge.
    static let statusTrailingGap: CGFloat = 8
    /// Inset to the right of the waveform on the active bar's right flank.
    static let waveformTrailingPad: CGFloat = 8
    /// FIXED width of the status-text slot on the active bar. The active notch is a
    /// constant footprint across every state (Listening / Thinking / Speaking /
    /// executing) — the text truncates with "…" inside this slot instead of resizing
    /// the notch. Sized to comfortably fit the standard state words.
    static let activeStatusTextWidth: CGFloat = 104
    static let waveformBoxSize: CGFloat = 26
    static let focusedEditUndoButtonSize: CGFloat = 28
    static let focusedEditUndoTrailingPad: CGFloat = 8

    // MARK: - Open/close morph timing

    /// Shared morph timing. The SwiftUI content morph (NotchContainerView) and the
    /// AppKit window-frame animation (NotchPanelController) use the SAME curve and
    /// duration so they move as one. No spring — a SwiftUI spring can't be matched
    /// by a Core Animation timing function, which is what caused the open/close
    /// desync (lag + transient sharp corners).
    static let morphDuration: Double = 0.36
    /// Cubic-bezier control points (shared by Animation.timingCurve and
    /// CAMediaTimingFunction). The slight y>1 gives a gentle overshoot.
    static let morphControlPoints: (c0x: Double, c0y: Double, c1x: Double, c1y: Double) = (0.34, 1.1, 0.64, 1.0)
}

/// Geometry for the active closed bar, derived from the current status text.
/// Both the SwiftUI layout and the host-window frame
/// (NotchPanelController) derive from this, so the displayed content and the
/// window can never disagree (no clipping, cutout stays centered).
struct ActiveBarMetrics: Equatable {
    var totalWidth: CGFloat
    var leftFlankWidth: CGFloat
    var textWidth: CGFloat
    var bridgeWidth: CGFloat
    var rightFlankWidth: CGFloat
}

@MainActor
final class NotchUIModel: ObservableObject {
    enum NotchState { case closed, open }

    @Published private(set) var notchState: NotchState = .closed

    /// The physical notch footprint (or the floating-bar footprint on non-notch
    /// displays). Width drives the closed-bar center gap; height is the menu-bar
    /// thickness. Measured once from the screen at init.
    @Published private(set) var closedNotchSize: CGSize

    /// The size the layout targets: the open content size while open, the closed
    /// footprint while closed. SwiftUI animates between the two.
    @Published private(set) var notchSize: CGSize

    /// True only on displays with a real hardware notch — used to decide whether
    /// the closed bar hugs a real cutout or renders as a standalone floating bar.
    let hasPhysicalNotch: Bool

    /// Convenience for views matching BoringViewModel's API name.
    var effectiveClosedNotchHeight: CGFloat { closedNotchSize.height }

    // MARK: - Active bar geometry

    /// The idle closed-bar geometry: just the centered cutout bridge (no logo, no
    /// status text, no waveform). Used when the assistant is at rest so the notch
    /// footprint is exactly the hardware cutout and clicks pass through everywhere
    /// else.
    var idleBarMetrics: ActiveBarMetrics {
        let bridge = max(0, closedNotchSize.width)
        return ActiveBarMetrics(
            totalWidth: bridge,
            leftFlankWidth: 0,
            textWidth: 0,
            bridgeWidth: bridge,
            rightFlankWidth: 0
        )
    }

    /// The active closed-bar geometry. It is a CONSTANT footprint for every active
    /// state — no logo, a fixed-width status-text slot on the left, the cutout bridge
    /// centered, and the fixed waveform slot on the right. The status text truncates
    /// inside its slot rather than resizing the notch, so the bar never changes size
    /// or re-centers while listening / thinking / speaking / executing. `text` is
    /// accepted only to keep a single call site; the geometry does not depend on it.
    func activeBarMetrics(for text: String) -> ActiveBarMetrics {
        _ = text
        let rightFlank = NotchConstants.waveformBoxSize + NotchConstants.waveformTrailingPad
        let bridge = max(0, closedNotchSize.width)
        let textW = NotchConstants.activeStatusTextWidth
        let leftFlank = NotchConstants.statusLeadingPad + textW + NotchConstants.statusTrailingGap
        return ActiveBarMetrics(
            totalWidth: leftFlank + bridge + rightFlank,
            leftFlankWidth: leftFlank,
            textWidth: textW,
            bridgeWidth: bridge,
            rightFlankWidth: rightFlank
        )
    }

    /// The focused-edit completion bar shares the expanded left text flank with
    /// the live status bar, while reserving a compact undo button on the right.
    /// The physical notch bridge stays centered; the extra leading padding grows
    /// the UI to the left rather than crowding text against its outer edge.
    func focusedEditCompletionBarMetrics() -> ActiveBarMetrics {
        let bridge = max(0, closedNotchSize.width)
        let leftFlank = NotchConstants.statusLeadingPad
            + NotchConstants.activeStatusTextWidth
            + NotchConstants.statusTrailingGap
        let rightFlank = NotchConstants.focusedEditUndoButtonSize
            + NotchConstants.focusedEditUndoTrailingPad
        return ActiveBarMetrics(
            totalWidth: leftFlank + bridge + rightFlank,
            leftFlankWidth: leftFlank,
            textWidth: NotchConstants.activeStatusTextWidth,
            bridgeWidth: bridge,
            rightFlankWidth: rightFlank
        )
    }

    init(screen: NSScreen?) {
        let resolved = Self.resolveClosedNotchSize(for: screen)
        self.closedNotchSize = resolved.size
        self.notchSize = resolved.size
        self.hasPhysicalNotch = resolved.hasNotch
    }

    func open() {
        notchSize = NotchConstants.openNotchSize
        notchState = .open
    }

    func close() {
        notchSize = closedNotchSize
        notchState = .closed
    }

    func toggle() {
        notchState == .open ? close() : open()
    }

    // MARK: - Screen measurement

    /// Computes the closed notch footprint the same way BoringNotch does:
    /// width = screen width minus the two menu-bar auxiliary areas (the regions
    /// flanking the hardware notch), height = the menu-bar thickness. Falls back
    /// to a floating-bar size on displays without a notch.
    private static func resolveClosedNotchSize(for screen: NSScreen?) -> (size: CGSize, hasNotch: Bool) {
        let barHeight = NSStatusBar.system.thickness

        guard let screen else {
            return (CGSize(width: NotchConstants.fallbackNotchWidth, height: barHeight), false)
        }

        let hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch,
           let leftPadding = screen.auxiliaryTopLeftArea?.width,
           let rightPadding = screen.auxiliaryTopRightArea?.width {
            // +4 matches BoringNotch's fudge so the shape slightly overlaps the
            // real cutout edges and reads as one continuous black notch.
            let measuredWidth = screen.frame.width - leftPadding - rightPadding + 4
            let width = measuredWidth > 0 ? measuredWidth : NotchConstants.fallbackNotchWidth
            let height = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : barHeight
            return (CGSize(width: width, height: height), true)
        }

        return (CGSize(width: NotchConstants.nonNotchBarWidth, height: barHeight), false)
    }
}
