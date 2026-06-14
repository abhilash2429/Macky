//
//  NotchPanelController.swift
//  leanring-buddy
//
//  Owns the notch bar panel and the drop panel beneath it.
//
//  The bar panel is pinned flush to the top center of the primary display and
//  blends with the hardware notch at idle. It observes CompanionManager.voiceState
//  and animates its WIDTH between the idle notch width and `expandedWidth` (480pt)
//  via NSAnimationContext. Its HEIGHT is fixed at `barHeight + pulseHeadroom`.
//
//  Milestone UI-4: a second NSPanel (the drop panel) sits flush under the bar,
//  hidden (alpha 0) until the user hovers or clicks the bar. It shows recent
//  interaction history and a file-drop zone. Hover is tracked on both panels;
//  leaving both dismisses the drop panel after a short delay.
//
//  Both panels accept mouse events at all times so the drop panel can be triggered
//  from the bar even while idle.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Borderless, non-activating panel. It never becomes key or main, so it floats
/// above other apps without ever stealing keyboard focus.
final class NotchBarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // .nonactivatingPanel: never bring this app forward; the user's
            // frontmost app keeps focus at all times.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Just above the status-bar level so the notch sits over everything.
        self.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // Clear/non-opaque so the hosted SwiftUI view paints the visible shape.
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        // Mouse events stay ON so hover/click can trigger the drop panel even when
        // the bar is idle.
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isExcludedFromWindowsMenu = true
    }

    // Never take focus away from whatever the user is working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hardware notch geometry resolved dynamically from the screen — never hardcoded.
private struct NotchGeometry {
    /// Visible width of the black bar at idle (hardware notch width, or the
    /// floating-bar width on non-notch displays).
    let idleWidth: CGFloat
    /// Height of the visible black bar (the menubar thickness).
    let barHeight: CGFloat
    let hasNotch: Bool

    /// Floating-bar width on displays without a physical notch.
    static let floatingBarWidth: CGFloat = 200
    /// Fallback notch width if the menubar auxiliary areas report nonsense.
    static let fallbackNotchWidth: CGFloat = 126

    /// Resolves the bar width, bar height, and notch presence for `screen`.
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let hasNotch = screen.safeAreaInsets.top > 0
        let barHeight = NSStatusBar.system.thickness

        let idleWidth: CGFloat
        if hasNotch {
            let notchLeft = screen.auxiliaryTopLeftArea?.maxX ?? 0
            let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.width
            let measured = notchRight - notchLeft
            idleWidth = measured > 0 ? measured : fallbackNotchWidth
        } else {
            idleWidth = floatingBarWidth
        }

        return NotchGeometry(idleWidth: idleWidth, barHeight: barHeight, hasNotch: hasNotch)
    }
}

/// Owns the notch bar + drop panel for the app's lifetime. Instantiated once by
/// the app delegate on launch and driven read-only by CompanionManager.voiceState.
@MainActor
final class NotchPanelController {
    /// Width the bar expands to when the user is interacting.
    static let expandedWidth: CGFloat = 480
    /// Transparent vertical room kept below the visible bar so the tool-call
    /// pulse can swell downward without the window clipping it.
    static let pulseHeadroom: CGFloat = 8
    /// Drop panel dimensions.
    static let dropPanelWidth: CGFloat = 480
    static let dropPanelHeight: CGFloat = 280

    private let companionManager: CompanionManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: Bar panel
    private var panel: NotchBarPanel?
    private var idleFrame: NSRect = .zero
    private var expandedFrame: NSRect = .zero
    private var isExpanded = false

    // MARK: Drop panel
    private var dropPanel: NotchBarPanel?
    private var dropPanelFrame: NSRect = .zero
    private var isDropPanelShown = false

    // MARK: Hover state / timers
    private var isHoveringBar = false
    private var isHoveringDropPanel = false
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        createPanels()
        observeVoiceState()
    }

    // MARK: - Expansion (bar)

    /// Expands the bar to `expandedWidth`. No-op if already expanded.
    func expand() {
        guard !isExpanded, let panel else { return }
        isExpanded = true
        animate(panel, to: expandedFrame)
    }

    /// Collapses the bar back to the idle notch width. No-op if already collapsed.
    func collapse() {
        guard isExpanded, let panel else { return }
        isExpanded = false
        animate(panel, to: idleFrame)
    }

    /// Animates the bar panel frame with a spring-ish overshoot.
    private func animate(_ panel: NotchBarPanel, to target: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Drop panel show/hide

    /// Hover changes on the bar: show after a short delay; on exit, schedule hide.
    func handleBarHover(_ hovering: Bool) {
        isHoveringBar = hovering
        if hovering {
            cancelHide()
            scheduleShow()
        } else {
            cancelShow()
            scheduleHide()
        }
    }

    /// Hover changes on the drop panel itself: keep it open while hovered.
    func handleDropPanelHover(_ hovering: Bool) {
        isHoveringDropPanel = hovering
        if hovering {
            cancelHide()
        } else {
            scheduleHide()
        }
    }

    /// Click on the bar toggles the drop panel.
    func toggleDropPanel() {
        if isDropPanelShown {
            hideDropPanel()
        } else {
            showDropPanel()
        }
    }

    private func scheduleShow() {
        cancelShow()
        let item = DispatchWorkItem { [weak self] in self?.showDropPanel() }
        showWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func scheduleHide() {
        cancelHide()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isHoveringBar, !self.isHoveringDropPanel else { return }
            self.hideDropPanel()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func cancelShow() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    /// Reveals the drop panel with a fade + small downward slide. Suppressed while
    /// our app reports fullscreen (best-effort — won't catch every other app's
    /// fullscreen space).
    func showDropPanel() {
        guard let dropPanel, !isDropPanelShown else { return }
        guard !NSApp.presentationOptions.contains(.fullScreen) else { return }
        isDropPanelShown = true

        // Start tucked slightly up behind the bar and transparent, then slide down
        // into place while fading in.
        dropPanel.setFrame(dropPanelFrame.offsetBy(dx: 0, dy: 10), display: false)
        dropPanel.alphaValue = 0
        dropPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropPanel.animator().setFrame(dropPanelFrame, display: true)
            dropPanel.animator().alphaValue = 1
        }
    }

    /// Fades the drop panel out and orders it off-screen so it stops receiving
    /// mouse events while hidden.
    func hideDropPanel() {
        guard let dropPanel, isDropPanelShown else { return }
        isDropPanelShown = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            dropPanel.animator().alphaValue = 0
        } completionHandler: { [weak dropPanel] in
            dropPanel?.orderOut(nil)
        }
    }

    // MARK: - State observation

    /// Drives expansion from voice activity: any non-idle state expands the bar,
    /// `.idle` collapses it. The initial `.idle` emission is a harmless no-op.
    private func observeVoiceState() {
        companionManager.$voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .idle {
                    self?.collapse()
                } else {
                    self?.expand()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel lifecycle

    /// Creates the bar panel (at idle) and the hidden drop panel beneath it.
    private func createPanels() {
        // Always NSScreen.main.frame — never visibleFrame (which excludes the
        // menu bar and would push the panel down below the notch).
        guard let screen = NSScreen.main else {
            print("⚠️ NotchPanel: no main screen; panels not created")
            return
        }

        let geometry = NotchGeometry.forScreen(screen)
        let panelHeight = geometry.barHeight + Self.pulseHeadroom

        idleFrame = barFrame(width: geometry.idleWidth, panelHeight: panelHeight, screen: screen)
        expandedFrame = barFrame(width: Self.expandedWidth, panelHeight: panelHeight, screen: screen)

        // Drop panel: 480 wide, centered like the expanded bar, flush below.
        dropPanelFrame = NSRect(
            x: expandedFrame.minX,
            y: idleFrame.minY - Self.dropPanelHeight,
            width: Self.dropPanelWidth,
            height: Self.dropPanelHeight
        )

        // ── Bar panel ───────────────────────────────────────────────────────
        let barPanel = NotchBarPanel(contentRect: idleFrame)
        let barHosting = NSHostingView(rootView: NotchBarView(
            companionManager: companionManager,
            realtimeClient: companionManager.realtimeClient,
            barHeight: geometry.barHeight,
            onHoverChange: { [weak self] hovering in self?.handleBarHover(hovering) },
            onTap: { [weak self] in self?.toggleDropPanel() }
        ))
        barHosting.frame = NSRect(origin: .zero, size: idleFrame.size)
        barHosting.autoresizingMask = [.width, .height]
        barPanel.contentView = barHosting
        barPanel.setFrame(idleFrame, display: true)
        barPanel.orderFrontRegardless()
        self.panel = barPanel

        // ── Drop panel (hidden) ─────────────────────────────────────────────
        let dropPanel = NotchBarPanel(contentRect: dropPanelFrame)
        dropPanel.hasShadow = true
        dropPanel.alphaValue = 0
        let dropHosting = NSHostingView(rootView: DropPanelView(
            companionManager: companionManager,
            onHoverChange: { [weak self] hovering in self?.handleDropPanelHover(hovering) }
        ))
        dropHosting.frame = NSRect(origin: .zero, size: dropPanelFrame.size)
        dropHosting.autoresizingMask = [.width, .height]
        dropPanel.contentView = dropHosting
        dropPanel.setFrame(dropPanelFrame, display: false)
        self.dropPanel = dropPanel

        print("🪟 NotchPanel created — hasNotch=\(geometry.hasNotch), idleFrame=\(idleFrame), dropFrame=\(dropPanelFrame)")
    }

    /// Builds a centered, top-flush bar panel frame of the given visible width.
    /// AppKit coordinates: y = 0 is the bottom of the screen.
    private func barFrame(width: CGFloat, panelHeight: CGFloat, screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - panelHeight,
            width: width,
            height: panelHeight
        )
    }
}
