//
//  OverlayWindow.swift
//  leanring-buddy
//
//  The notch panel: a borderless, non-focus-stealing NSPanel whose frame IS the
//  hardware notch. Its black background is the visible notch fill. The panel
//  frame is computed from NSScreen.main (never visibleFrame) and pinned flush to
//  the top of the screen — its Y and height never change. For the active voice
//  states the panel animates its WIDTH only, expanding to 380pt centered on the
//  screen; at idle it returns to the exact hardware-notch frame.
//
//  Resizing the real panel frame (rather than animating SwiftUI content) avoids
//  the NSHostingView safe-area inset that otherwise pushes content down below the
//  notch. NotchView is still hosted as the content view, but the panel's own
//  black backgroundColor provides the notch visual.
//
//  This replaces the previous full-screen blue-cursor overlay. `OverlayWindowManager`
//  keeps the exact public API CompanionManager already calls; the panel is
//  persistent, so the hide methods are no-ops.
//

import AppKit
import Combine
import SwiftUI

/// Borderless panel for the notch. It never becomes key or main, so it can float
/// above other apps without ever stealing keyboard focus, and it ignores mouse
/// events so it's fully click-through.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Just above the status-bar level so the notch sits over everything.
        self.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Clear (not black): the visible black fill comes from a content view whose
        // bottom corners are rounded. A black window background would square off
        // those corners and overlap the real screen pixels around the hardware
        // notch's rounded underside, so it wouldn't blend.
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true   // click-through; nothing interactive here

        // Not in the spec's property list, but required for the notch to behave
        // as a persistent fixture: stay visible when the app isn't active, never
        // get released out from under us, and stay out of the Window menu.
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isExcludedFromWindowsMenu = true
    }

    // Never take focus away from whatever the user is working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the notch geometry NotchView reads. Only `isActive` changes at runtime.
/// (The panel frame is what actually animates; this keeps the hosted SwiftUI
/// content in sync.)
@MainActor
final class NotchPanelViewModel: ObservableObject {
    /// Idle pill width — the hardware notch width.
    let idleWidth: CGFloat
    /// Width the notch expands to while listening / thinking / speaking.
    let expandedWidth: CGFloat
    /// Locked notch height. Never changes.
    let notchHeight: CGFloat

    /// True while the companion is listening, thinking, or speaking.
    @Published var isActive: Bool = false

    init(idleWidth: CGFloat, expandedWidth: CGFloat, notchHeight: CGFloat) {
        self.idleWidth = idleWidth
        self.expandedWidth = expandedWidth
        self.notchHeight = notchHeight
    }
}

// Manager for the notch panel. Owns the single persistent NotchPanel and keeps
// the public API that CompanionManager relies on. The panel is shown once and
// never torn down; the hide methods are intentionally no-ops.
@MainActor
class OverlayWindowManager {
    private var notchPanel: NotchPanel?
    private var viewModel: NotchPanelViewModel?
    private var voiceStateCancellable: AnyCancellable?

    /// The exact hardware-notch frame (idle) and the expanded 380pt frame.
    /// Both share the same Y and height — only the width and X differ.
    private var idleFrame: NSRect = .zero
    private var expandedFrame: NSRect = .zero

    /// Retained only for API compatibility with CompanionManager's
    /// first-appearance bookkeeping. It no longer affects the panel.
    var hasShownOverlayBefore = false

    /// Width the notch expands to horizontally during the active voice states.
    private let expandedWidth: CGFloat = 380

    /// Bottom-corner radius for the notch fill, matched to the hardware notch's
    /// rounded underside so the idle panel blends with it. Tweak to fine-tune the
    /// blend on different displays.
    private let notchBottomCornerRadius: CGFloat = 10

    init() {
        showNotchPanel()
    }

    // MARK: - Public API (called by CompanionManager)

    /// Ensures the notch panel is present and frontmost, and (once) starts
    /// reacting to the companion's voice state. The `screens` argument is ignored
    /// now that the notch no longer hosts the cursor; the parameters are kept so
    /// existing call sites compile unchanged.
    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        showNotchPanel()
        observeVoiceState(of: companionManager)
    }

    /// No-op: the notch panel is persistent and blends with the hardware notch,
    /// so there is nothing to hide. Kept for API compatibility.
    func hideOverlay() {}

    /// No-op for the same reason as `hideOverlay()`. Kept for API compatibility.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {}

    func isShowingOverlay() -> Bool {
        return notchPanel != nil
    }

    // MARK: - Voice State

    /// Expands the notch while the companion is listening / thinking / speaking
    /// and collapses it back to the hardware notch at idle. Idempotent — only the
    /// first call wires the subscription.
    private func observeVoiceState(of companionManager: CompanionManager) {
        guard voiceStateCancellable == nil else { return }
        voiceStateCancellable = companionManager.$voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState in
                self?.setActive(voiceState != .idle)
            }
    }

    /// Animates the panel between the idle (notch) frame and the expanded frame.
    /// Width-only: both frames share Y and height, so the notch never moves down
    /// and never gets taller.
    private func setActive(_ isActive: Bool) {
        viewModel?.isActive = isActive

        guard let panel = notchPanel else { return }
        let targetFrame = isActive ? expandedFrame : idleFrame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Panel Lifecycle

    /// Creates the notch panel once (at the exact hardware-notch frame) and orders
    /// it front. Subsequent calls just re-show the existing panel.
    private func showNotchPanel() {
        if let notchPanel {
            notchPanel.orderFrontRegardless()
            return
        }

        // Always NSScreen.main.frame — never visibleFrame (which excludes the
        // menu bar and would push the notch down).
        guard let screen = NSScreen.main else { return }

        let notchHeight = screen.safeAreaInsets.top
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = screen.frame.width - leftWidth - rightWidth
        let notchX = screen.frame.origin.x + leftWidth
        let notchY = screen.frame.maxY - notchHeight   // AppKit: y = 0 is the bottom

        idleFrame = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
        expandedFrame = NSRect(
            x: screen.frame.midX - expandedWidth / 2,
            y: notchY,
            width: expandedWidth,
            height: notchHeight
        )

        let viewModel = NotchPanelViewModel(
            idleWidth: notchWidth,
            expandedWidth: expandedWidth,
            notchHeight: notchHeight
        )
        self.viewModel = viewModel

        let panel = NotchPanel(contentRect: idleFrame)

        // A black fill view with ONLY its bottom corners rounded gives the notch
        // its rounded underside so it blends with the hardware cutout; the top
        // edge stays square (flush with the top of the screen). NotchView is
        // hosted inside it, clipped to the same shape.
        let notchFillView = NSView(frame: NSRect(origin: .zero, size: idleFrame.size))
        notchFillView.wantsLayer = true
        notchFillView.layer?.backgroundColor = NSColor.black.cgColor
        notchFillView.layer?.cornerRadius = notchBottomCornerRadius
        notchFillView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        notchFillView.layer?.masksToBounds = true
        notchFillView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: NotchView(viewModel: viewModel))
        hostingView.frame = notchFillView.bounds
        hostingView.autoresizingMask = [.width, .height]
        notchFillView.addSubview(hostingView)

        panel.contentView = notchFillView

        panel.setFrame(idleFrame, display: true)
        panel.orderFrontRegardless()
        notchPanel = panel
    }
}
