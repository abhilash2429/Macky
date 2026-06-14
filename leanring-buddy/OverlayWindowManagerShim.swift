//
//  OverlayWindowManagerShim.swift
//  leanring-buddy
//
//  Temporary no-op compatibility shim. The old OverlayWindow.swift (which defined
//  the real OverlayWindowManager + NotchView) was removed in Milestone UI-1 and
//  replaced by NotchPanelController, which owns the notch panel independently.
//
//  CompanionManager still holds an `overlayWindowManager` and calls it in ~10
//  places. To keep CompanionManager compiling byte-for-byte unchanged (and to
//  leave the voice pipeline untouched this milestone), this stub preserves the
//  exact API CompanionManager uses — every method is an intentional no-op.
//
//  TODO: Remove this shim when CompanionManager is migrated to drive
//  NotchPanelController directly (a later UI milestone).
//

import AppKit

@MainActor
final class OverlayWindowManager {
    /// Retained only for CompanionManager's first-appearance bookkeeping. It no
    /// longer affects any panel.
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {}

    func hideOverlay() {}

    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {}

    func isShowingOverlay() -> Bool { false }

    func setExpanded(_ expanded: Bool) {}
}
