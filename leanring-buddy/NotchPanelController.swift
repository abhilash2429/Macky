//
//  NotchPanelController.swift
//  leanring-buddy
//
//  Owns the single borderless NSPanel pinned to the top-center of the primary
//  display, hosting NotchContainerView.
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

/// Borderless panel for the notch UI. It can become key when the user clicks
/// into panel controls, because auth, onboarding, settings, and file prompts all
/// live inside this surface now.
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    /// A little vertical headroom under the closed bar so the shape's bottom
    /// corner flare isn't clipped.
    static let closedBottomHeadroom: CGFloat = 8

    /// The notch panel's normal level: above the menu bar so it overlays the
    /// hardware cutout.
    private static let pinnedLevel = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)

    private let companionManager: CompanionManager
    private let notchModel: NotchUIModel
    private var cancellables = Set<AnyCancellable>()
    /// Restores the pinned window level after a system permission dialog; cancelled
    /// and rescheduled if another prompt fires while one is already pending.
    private var levelRestoreTask: Task<Void, Never>?
    private var didBecomeActiveObserver: NSObjectProtocol?

    private var panel: NotchHostPanel?
    /// The screen the frames are computed against (cached so the dynamic active
    /// frame can be recomputed as the status text changes).
    private var screen: NSScreen?
    private var idleClosedFrame: NSRect = .zero
    private var openFrame: NSRect = .zero

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

        print("🪟 NotchPanel created — notch=\(notchModel.hasPhysicalNotch), idle=\(idleClosedFrame), open=\(openFrame)")
    }

    /// Computes the three centered, top-flush frames. AppKit coords: y=0 is the
    /// bottom of the screen, so the top edge is `screen.frame.maxY`.
    private func computeFrames(for screen: NSScreen) {
        let closedHeight = notchModel.closedNotchSize.height + Self.closedBottomHeadroom
        let top = screen.frame.maxY

        func centered(width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        }

        // Idle keeps the cutout bridge centered on the screen while the persistent
        // logo flank extends asymmetrically to the left (same scheme as activeFrame).
        let idle = notchModel.idleBarMetrics
        idleClosedFrame = NSRect(
            x: screen.frame.midX - idle.leftFlankWidth - idle.bridgeWidth / 2,
            y: top - closedHeight,
            width: idle.totalWidth,
            height: closedHeight
        )
        openFrame = centered(width: NotchConstants.windowSize.width, height: NotchConstants.windowSize.height)
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

    /// The frame the closed notch should occupy right now. While the assistant is
    /// active it's the constant active bar (matches what `AurenStatusBar` renders,
    /// including states with no status text like continuous-listening); otherwise the
    /// bare idle cutout. Keying off `isAssistantActive` — not whether the text is
    /// empty — keeps the window from clipping the waveform in a text-less active state.
    private func closedTargetFrame(for screen: NSScreen) -> NSRect {
        guard companionManager.isAssistantActive else { return idleClosedFrame }
        return activeFrame(for: screen, text: companionManager.activeStatusText)
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

        // While closed, switch between the idle cutout and the constant active bar as
        // the assistant becomes active/idle. Every signal that feeds `isAssistantActive`
        // / `activeStatusText` is a trigger, so the frame can't lag behind what the
        // status bar renders (including a text-less active state).
        let activityA = Publishers.CombineLatest3(
            companionManager.$voiceState,
            companionManager.$toolCallActive,
            companionManager.$narrationText
        )
        .map { _, _, _ in () }

        let activityB = companionManager.$operationState.map { _ in () }

        Publishers.Merge(activityA, activityB)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyClosedActivity()
            }
            .store(in: &cancellables)

        // When a native permission dialog is about to appear, drop the panel below
        // it so the dialog isn't hidden behind the notch. `dropDuplicates`/skipping
        // the initial 0 avoids reacting to the published default value on launch.
        companionManager.$systemPromptToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lowerLevelForSystemPrompt()
            }
            .store(in: &cancellables)
    }

    // MARK: - System permission dialog handling

    /// Temporarily lowers the panel to normal window level so a system (TCC)
    /// permission dialog renders above it, then restores the pinned level after the
    /// dialog is dealt with (on app reactivation, or an 8s fallback).
    private func lowerLevelForSystemPrompt() {
        guard let panel else { return }
        panel.level = .normal

        // Restore when the user returns to the app after answering the dialog.
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restorePinnedLevel() }
            }
        }

        // Fallback in case the activation notification never arrives.
        levelRestoreTask?.cancel()
        levelRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.restorePinnedLevel()
        }
    }

    private func restorePinnedLevel() {
        levelRestoreTask?.cancel()
        levelRestoreTask = nil
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
        panel?.level = Self.pinnedLevel
    }

    private func handleNotchState(_ state: NotchUIModel.NotchState) {
        guard let panel, let screen else { return }
        let target = state == .open ? openFrame : closedTargetFrame(for: screen)
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
