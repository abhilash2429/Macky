//
//  NotchUIModel.swift
//  leanring-buddy
//
//  The Speed-native replacement for BoringNotch's BoringViewModel — but trimmed
//  to only what the ported Auren views actually read. It owns two things:
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
    /// The expanded panel's content size (matches BoringNotch's openNotchSize).
    static let openNotchSize = CGSize(width: 640, height: 190)
    /// Transparent breathing room around the panel so the drop shadow isn't clipped.
    static let shadowPadding: CGFloat = 20
    /// Total host-window size when open (content + shadow padding).
    static let windowSize = CGSize(
        width: openNotchSize.width,
        height: openNotchSize.height + shadowPadding
    )
    /// Corner radii for the NotchShape in each state: (top, bottom).
    static let openedCornerRadius: (top: CGFloat, bottom: CGFloat) = (top: 19, bottom: 24)
    static let closedCornerRadius: (top: CGFloat, bottom: CGFloat) = (top: 6, bottom: 14)
    /// Fallback notch width when the screen's menu-bar auxiliary areas misreport.
    static let fallbackNotchWidth: CGFloat = 185
    /// Width of the floating bar on displays that have no physical notch.
    static let nonNotchBarWidth: CGFloat = 220
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

    /// Convenience the Auren views read, matching BoringViewModel's API name.
    var effectiveClosedNotchHeight: CGFloat { closedNotchSize.height }

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