//
//  NotchPanelController.swift
//  leanring-buddy
//
//  Rewritten for the Auren UI. Owns a single borderless, non-activating NSPanel
//  pinned to the top-center of the primary display, hosting NotchContainerView.
//
//  The closed↔open MORPH is done in SwiftUI (NotchShape animating its height +
//  corner radii). This controller's only job on top of that is to resize the
//  PANEL FRAME to match, across three sizes:
//
//    • idleClosedFrame  — exactly the notch footprint, so clicks pass through to
//                         apps underneath when the assistant is idle.
//    • activeClosedFrame — the notch plus room on either flank for the status
//                          text + waveform while the assistant is active.
//    • openFrame        — 640 wide and as tall as the panel's measured content
//                          (up to maxOpenHeight), dropping below the notch.
//
//  It observes NotchUIModel.notchState (open/close), NotchUIModel.openContentHeight
//  (the measured open height) and CompanionManager's voiceState/toolCallActive
//  (active/idle) to pick the right frame. While open, the frame re-animates to hug
//  the content as it changes.
//

import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel. Never becomes key/main, so it floats above
/// other apps without ever stealing keyboard focus — the user's frontmost app
/// keeps focus even while the notch is open.
///
/// Known limitation: because this never becomes key, the text field in the
/// file-input panel can't receive typed input. Dropping files and sending works;
/// typed prompts need a focus-toggling variant (a documented follow-up).
final class NotchHostPanel: NSPanel {
    /// Normally false so the panel never steals focus from the frontmost app. The
    /// controller flips this on while the panel hosts the auth/onboarding surface,
    /// which need keyboard input (email field, hotkey recorder). The
    /// `.nonactivatingPanel` style means becoming key routes key events without
    /// activating Speed or backgrounding the user's current app.
    var allowsKeyboardFocus = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isExcludedFromWindowsMenu = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    /// A little vertical headroom under the closed bar so the shape's bottom
    /// corner flare isn't clipped.
    static let closedBottomHeadroom: CGFloat = 8

    private let companionManager: CompanionManager
    private let notchModel: NotchUIModel
    private var cancellables = Set<AnyCancellable>()

    private var panel: NotchHostPanel?
    /// The screen the frames are computed against (cached so the dynamic active
    /// frame can be recomputed as the status text changes).
    private var screen: NSScreen?
    private var idleClosedFrame: NSRect = .zero

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.notchModel = NotchUIModel(screen: NSScreen.main)
        createPanel()
        observeState()
    }

    // MARK: - Panel creation

    private func createPanel() {
        guard let screen = NSScreen.main else {
            print("⚠️ NotchPanel: no main screen; panel not created")
            return
        }
        self.screen = screen

        computeFrames(for: screen)

        let panel = NotchHostPanel(contentRect: idleClosedFrame)
        let hosting = NSHostingView(
            rootView: NotchContainerView(companionManager: companionManager)
                .environmentObject(notchModel)
        )
        hosting.sizingOptions = []

        // NSHostingView auto-resizes its window to match SwiftUI's fitting size,
        // but ONLY while it is the window's contentView — it does so by calling
        // window.setFrame from inside the layout pass (updateAnimatedWindowSize).
        // Our controller already owns the panel frame, and the notch content
        // changes size as it morphs open/closed, so that auto-resize re-enters the
        // display cycle and crashes with the "needs another Update Constraints in
        // Window pass" NSGenericException. Hosting SwiftUI inside a plain container
        // view (so the hosting view is NOT the contentView) removes it from the
        // window-sizing path entirely while still filling the panel via autoresize.
        let container = NSView(frame: NSRect(origin: .zero, size: idleClosedFrame.size))
        container.autoresizesSubviews = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.setFrame(idleClosedFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        print("🪟 NotchPanel (Auren) created — notch=\(notchModel.hasPhysicalNotch), idle=\(idleClosedFrame), open=\(openTargetFrame(for: screen))")
    }

    /// Computes the static idle closed frame (the notch footprint). The active
    /// closed bar and the open frame are computed on demand (the latter from the
    /// measured content height). AppKit coords: y=0 is the bottom of the screen,
    /// so the top edge is `screen.frame.maxY`.
    private func computeFrames(for screen: NSScreen) {
        let closedSize = notchModel.closedNotchSize
        let closedHeight = closedSize.height + Self.closedBottomHeadroom
        let top = screen.frame.maxY

        func centered(width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        }

        idleClosedFrame = centered(width: closedSize.width, height: closedHeight)
    }

    /// The open frame, sized to the panel's current measured content height
    /// (clamped to [minOpenHeight, maxOpenHeight]) plus shadow padding. Recomputed
    /// on demand so the window hugs the content as it changes.
    private func openTargetFrame(for screen: NSScreen) -> NSRect {
        let width = NotchConstants.windowSize.width
        let clamped = min(max(notchModel.openContentHeight, NotchConstants.minOpenHeight), NotchConstants.maxOpenHeight)
        let height = clamped + NotchConstants.shadowPadding
        let top = screen.frame.maxY
        return NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
    }

    /// The closed-bar frame sized to fit `text`, positioned so the cutout bridge
    /// stays centered on `screen.midX` even though the bar extends asymmetrically
    /// (more to the left when the text is longer than the waveform).
    private func activeFrame(for screen: NSScreen, text: String) -> NSRect {
        let m = notchModel.activeBarMetrics(for: text)
        let height = notchModel.closedNotchSize.height + Self.closedBottomHeadroom
        let top = screen.frame.maxY
        let originX = screen.frame.midX - m.leftFlankWidth - m.bridgeWidth / 2
        return NSRect(x: originX, y: top - height, width: m.totalWidth, height: height)
    }

    /// The frame the closed notch should occupy right now, given the live status
    /// text (idle footprint when there's nothing to show).
    private func closedTargetFrame(for screen: NSScreen) -> NSRect {
        let text = companionManager.activeStatusText
        return text.isEmpty ? idleClosedFrame : activeFrame(for: screen, text: text)
    }

    // MARK: - State observation

    private func observeState() {
        // Open/close drives the big morph: the window animates in lockstep with
        // the SwiftUI content over the shared morph timeline (no blind delay).
        notchModel.$notchState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleNotchState(state)
            }
            .store(in: &cancellables)

        // While closed, resize the window to fit the live status text (or the
        // idle cutout when there's nothing to show). Narration changes the text
        // too, so it's part of the trigger.
        Publishers.CombineLatest3(
            companionManager.$voiceState,
            companionManager.$toolCallActive,
            companionManager.$narrationText
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.applyClosedActivity()
        }
        .store(in: &cancellables)

        // While open, the panel hugs its content: re-animate the frame to fit the
        // measured content height as it changes (idle ↔ review ↔ drop, data loads).
        notchModel.$openContentHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyOpenHeight()
            }
            .store(in: &cancellables)

        // Auth/onboarding need keyboard input (email field, hotkey recorder), so
        // make the panel key while those surfaces show and give focus back to the
        // user's app otherwise.
        companionManager.$panelDisplayState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyKeyboardFocus(for: state)
            }
            .store(in: &cancellables)
    }

    /// Lets the panel become key only for the auth/onboarding surfaces. Leaving
    /// those surfaces just clears the flag — once `canBecomeKey` is false again the
    /// system hands key status back to the user's app on their next interaction
    /// (AppKit forbids invoking `resignKey()` directly).
    private func applyKeyboardFocus(for state: PanelDisplayState) {
        guard let panel else { return }
        switch state {
        case .auth, .onboarding:
            panel.allowsKeyboardFocus = true
            panel.makeKey()
        default:
            panel.allowsKeyboardFocus = false
        }
    }

    private func handleNotchState(_ state: NotchUIModel.NotchState) {
        guard let panel, let screen else { return }
        let target = state == .open ? openTargetFrame(for: screen) : closedTargetFrame(for: screen)
        animateMorph(panel, to: target)
    }

    private func applyOpenHeight() {
        guard let panel, let screen, notchModel.notchState == .open else { return }
        let target = openTargetFrame(for: screen)
        guard panel.frame != target else { return }
        animateMorph(panel, to: target)
    }

    private func applyClosedActivity() {
        guard let panel, let screen, notchModel.notchState == .closed else { return }
        let target = closedTargetFrame(for: screen)
        // Compare the full rect: the origin moves (not just the width) as the
        // left flank grows, so a width-only check would miss the re-centering.
        guard panel.frame != target else { return }
        animateMorph(panel, to: target)
    }

    private func animateMorph(_ panel: NotchHostPanel, to target: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NotchConstants.morphDuration
            let p = NotchConstants.morphControlPoints
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(p.c0x), Float(p.c0y), Float(p.c1x), Float(p.c1y)
            )
            panel.animator().setFrame(target, display: true)
        }
    }
}