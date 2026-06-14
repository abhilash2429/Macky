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
//    • openFrame        — the full 640×210 panel that drops below the notch.
//
//  It observes NotchUIModel.notchState (open/close) and CompanionManager's
//  voiceState/toolCallActive (active/idle) to pick the right frame. The panel is
//  made large the instant it opens (so the expanding SwiftUI content is never
//  clipped) and shrunk only after the collapse animation finishes.
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    /// Extra width added on each closed flank when the assistant is active, so
    /// the status text and waveform have menu-bar room beside the cutout.
    static let activeClosedFlankWidth: CGFloat = 200
    /// A little vertical headroom under the closed bar so the shape's bottom
    /// corner flare isn't clipped.
    static let closedBottomHeadroom: CGFloat = 8

    private let companionManager: CompanionManager
    private let notchModel: NotchUIModel
    private var cancellables = Set<AnyCancellable>()

    private var panel: NotchHostPanel?
    private var idleClosedFrame: NSRect = .zero
    private var activeClosedFrame: NSRect = .zero
    private var openFrame: NSRect = .zero

    /// Cached so we only resize when the closed size actually needs to change.
    private var lastClosedWasActive = false
    private var shrinkTask: Task<Void, Never>?

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

        print("🪟 NotchPanel (Auren) created — notch=\(notchModel.hasPhysicalNotch), idle=\(idleClosedFrame), open=\(openFrame)")
    }

    /// Computes the three centered, top-flush frames. AppKit coords: y=0 is the
    /// bottom of the screen, so the top edge is `screen.frame.maxY`.
    private func computeFrames(for screen: NSScreen) {
        let closedSize = notchModel.closedNotchSize
        let closedHeight = closedSize.height + Self.closedBottomHeadroom
        let top = screen.frame.maxY

        func centered(width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        }

        idleClosedFrame = centered(width: closedSize.width, height: closedHeight)
        activeClosedFrame = centered(width: closedSize.width + Self.activeClosedFlankWidth, height: closedHeight)
        openFrame = centered(width: NotchConstants.windowSize.width, height: NotchConstants.windowSize.height)
    }

    // MARK: - State observation

    private func observeState() {
        // Open/close drives the big morph: grow the window the instant we open,
        // shrink it only after the SwiftUI collapse animation has played out.
        notchModel.$notchState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleNotchState(state)
            }
            .store(in: &cancellables)

        // While closed, widen/narrow the window between the active and idle
        // footprints as the assistant becomes active or returns to idle.
        Publishers.CombineLatest(companionManager.$voiceState, companionManager.$toolCallActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState, toolActive in
                guard let self else { return }
                let active = voiceState != .idle || toolActive
                self.applyClosedActivity(active)
            }
            .store(in: &cancellables)
    }

    private func handleNotchState(_ state: NotchUIModel.NotchState) {
        guard let panel else { return }
        shrinkTask?.cancel()

        switch state {
        case .open:
            // Grow first so the expanding content is never clipped.
            panel.setFrame(openFrame, display: true)
        case .closed:
            // Let the SwiftUI shape finish collapsing, then shrink the window
            // back to the appropriate closed footprint.
            shrinkTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.notchModel.notchState == .closed else { return }
                let target = self.lastClosedWasActive ? self.activeClosedFrame : self.idleClosedFrame
                self.animate(panel, to: target)
            }
        }
    }

    private func applyClosedActivity(_ active: Bool) {
        lastClosedWasActive = active
        guard let panel, notchModel.notchState == .closed else { return }
        let target = active ? activeClosedFrame : idleClosedFrame
        guard panel.frame.width != target.width else { return }
        animate(panel, to: target)
    }

    private func animate(_ panel: NotchHostPanel, to target: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.1, 0.64, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }
}