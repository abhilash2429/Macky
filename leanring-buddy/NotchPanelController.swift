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

/// The history panel that grows straight down from the notch bar on hover/click.
/// Same borderless, non-activating, clear-background pattern as NotchBarPanel.
/// Mouse events stay ON so the history list can be scrolled.
final class HistoryPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Match the bar's level so the two sit on the same plane at the seam.
        self.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        // Mouse ON: the panel needs scroll interaction for the history list.
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The drop zone that animates down from the notch bar during a file drag. Same
/// borderless, non-activating, clear-background, black-fill treatment as the
/// history panel, but visible only while a drag is in progress. Mouse events stay
/// ON so it can itself be a drop target when the cursor moves onto it.
final class DropZonePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        // Mouse ON so dragging onto the zone keeps the drag alive and drops land.
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A drag-detection NSView that accepts dragged file URLs and forwards the drag
/// lifecycle to the controller via closures. Wraps a hosted SwiftUI view (the
/// notch bar or the drop zone) so file drags are detected without disturbing the
/// subview's normal mouse events — hover and click still reach the SwiftUI view,
/// keeping the history panel's behavior intact.
final class DragDetectionView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        return onPerformDrop?(urls) ?? false
    }
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

/// Backing state for the notch bar's three regions. The controller owns this and
/// pushes derived values into it (see observeVoiceState); NotchBarView observes it
/// and renders, so the bar view stays decoupled from CompanionManager and
/// RealtimeClient — and Session D can feed it real narration / output values.
@MainActor
final class NotchPanelViewModel: ObservableObject {
    /// Left-flank label for the current voice state ("Listening" / "Thinking" /
    /// "Speaking"). Empty at idle, which collapses the left flank to zero width.
    @Published var activityText: String = ""

    /// Whether a tool call is in flight. Drives the left-flank braille spinner.
    @Published var isToolActive: Bool = false

    /// Normalized 0–1 loudness driving the right-flank waveform. Sourced from mic
    /// input while listening and model playback while speaking.
    @Published var waveformLevel: CGFloat = 0
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
    /// Fixed height of the history panel that grows down from the bar. Shows
    /// roughly 4–5 rows; not user-resizable in this session.
    static let historyPanelHeight: CGFloat = 180
    /// Fixed height of the drop zone that animates down during a file drag.
    static let dropZoneHeight: CGFloat = 120
    /// Bottom corner radius shared by the notch bar's visible shape and the
    /// history panel below it, so the two read as one continuous surface.
    /// (NotchBarShape independently uses this same value; it can't be unified
    /// without touching that off-limits file.)
    static let notchBottomCornerRadius: CGFloat = 10

    private let companionManager: CompanionManager
    private let realtimeClient: RealtimeClient
    private var cancellables = Set<AnyCancellable>()

    /// State the hosted NotchBarView observes. Driven by observeVoiceState.
    let viewModel = NotchPanelViewModel()

    /// Drives the synthetic "thinking" waveform pulse while processing; nil otherwise.
    private var thinkingPulseCancellable: AnyCancellable?
    private var thinkingPulsePhase: Double = 0

    // MARK: Bar panel
    private var panel: NotchBarPanel?
    private var idleFrame: NSRect = .zero
    private var expandedFrame: NSRect = .zero
    private var isExpanded = false

    // MARK: History panel
    private var historyPanel: HistoryPanel?
    private var historyPanelFrame: NSRect = .zero
    private var isHistoryPanelShown = false

    // MARK: Drop zone panel
    private var dropZonePanel: DropZonePanel?
    private var dropZonePanelFrame: NSRect = .zero
    private var isDropZoneShown = false
    /// Which drag-detection regions the cursor is currently over, so moving
    /// between the notch and the drop zone doesn't dismiss the zone mid-drag.
    private var isDragOverNotch = false
    private var isDragOverZone = false
    private var dropZoneHideWorkItem: DispatchWorkItem?

    // MARK: Hover state / timers
    private var isHoveringBar = false
    private var isHoveringHistoryPanel = false
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.realtimeClient = companionManager.realtimeClient
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

    // MARK: - History panel show/hide

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

    /// Hover changes on the history panel itself: keep it open while hovered.
    func handleHistoryPanelHover(_ hovering: Bool) {
        isHoveringHistoryPanel = hovering
        if hovering {
            cancelHide()
        } else {
            scheduleHide()
        }
    }

    /// Click on the bar toggles the history panel.
    func toggleHistoryPanel() {
        if isHistoryPanelShown {
            hideHistoryPanel()
        } else {
            showHistoryPanel()
        }
    }

    private func scheduleShow() {
        cancelShow()
        let item = DispatchWorkItem { [weak self] in self?.showHistoryPanel() }
        showWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func scheduleHide() {
        cancelHide()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isHoveringBar, !self.isHoveringHistoryPanel else { return }
            self.hideHistoryPanel()
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

    /// The history panel frame for the bar's CURRENT width (idle or expanded),
    /// flush against the visible bar's bottom edge with no gap or seam. The bar
    /// panel keeps `pulseHeadroom` of transparent space below the visible black
    /// bar, so the panel's top is offset up by that amount to sit flush.
    private func currentHistoryPanelFrame() -> NSRect {
        guard let panel else { return historyPanelFrame }
        let barFrame = panel.frame
        let flushTopY = barFrame.origin.y + Self.pulseHeadroom
        return NSRect(
            x: barFrame.origin.x,
            y: flushTopY - Self.historyPanelHeight,
            width: barFrame.width,
            height: Self.historyPanelHeight
        )
    }

    /// Reveals the history panel with a fade + small downward slide, sized to the
    /// notch bar's current width so there's zero horizontal gap. Suppressed while
    /// our app reports fullscreen (best-effort — won't catch every other app's
    /// fullscreen space).
    func showHistoryPanel() {
        guard let historyPanel, !isHistoryPanelShown else { return }
        guard !NSApp.presentationOptions.contains(.fullScreen) else { return }
        isHistoryPanelShown = true

        // Recompute width/position live so it matches the bar's current state.
        historyPanelFrame = currentHistoryPanelFrame()

        // Start tucked slightly up behind the bar and transparent, then slide down
        // into place while fading in.
        historyPanel.setFrame(historyPanelFrame.offsetBy(dx: 0, dy: 10), display: false)
        historyPanel.alphaValue = 0
        historyPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            historyPanel.animator().setFrame(historyPanelFrame, display: true)
            historyPanel.animator().alphaValue = 1
        }
    }

    /// Fades the history panel out and orders it off-screen so it stops receiving
    /// mouse events while hidden.
    func hideHistoryPanel() {
        guard let historyPanel, isHistoryPanelShown else { return }
        isHistoryPanelShown = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            historyPanel.animator().alphaValue = 0
        } completionHandler: { [weak historyPanel] in
            historyPanel?.orderOut(nil)
        }
    }

    // MARK: - Drop zone (file drag) show/hide

    /// A drag entered the notch or the drop zone: keep the zone visible.
    private func handleDragEntered(overZone: Bool) {
        if overZone { isDragOverZone = true } else { isDragOverNotch = true }
        cancelDropZoneHide()
        showDropZone()
    }

    /// A drag left the notch or the drop zone: dismiss shortly unless it re-enters
    /// the other region (covers the cursor moving between the two).
    private func handleDragExited(overZone: Bool) {
        if overZone { isDragOverZone = false } else { isDragOverNotch = false }
        scheduleDropZoneHide()
    }

    /// Files were dropped: queue them for the next turn and dismiss the zone.
    private func handleDrop(_ urls: [URL]) -> Bool {
        isDragOverNotch = false
        isDragOverZone = false
        cancelDropZoneHide()
        companionManager.enqueueDroppedFiles(urls)
        hideDropZone()
        return !urls.isEmpty
    }

    private func scheduleDropZoneHide() {
        cancelDropZoneHide()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragOverNotch, !self.isDragOverZone else { return }
            self.hideDropZone()
        }
        dropZoneHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func cancelDropZoneHide() {
        dropZoneHideWorkItem?.cancel()
        dropZoneHideWorkItem = nil
    }

    /// The drop zone frame for the bar's CURRENT width, flush against the visible
    /// bar's bottom edge (same flush math as the history panel).
    private func currentDropZoneFrame() -> NSRect {
        guard let panel else { return dropZonePanelFrame }
        let barFrame = panel.frame
        let flushTopY = barFrame.origin.y + Self.pulseHeadroom
        return NSRect(
            x: barFrame.origin.x,
            y: flushTopY - Self.dropZoneHeight,
            width: barFrame.width,
            height: Self.dropZoneHeight
        )
    }

    /// Animates the drop zone down from the bar with a spring overshoot (matching
    /// the bar's expand animation), sized to the bar's current width.
    private func showDropZone() {
        guard let dropZonePanel, !isDropZoneShown else { return }
        guard !NSApp.presentationOptions.contains(.fullScreen) else { return }
        isDropZoneShown = true

        dropZonePanelFrame = currentDropZoneFrame()
        dropZonePanel.setFrame(dropZonePanelFrame.offsetBy(dx: 0, dy: 12), display: false)
        dropZonePanel.alphaValue = 0
        dropZonePanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            dropZonePanel.animator().setFrame(dropZonePanelFrame, display: true)
            dropZonePanel.animator().alphaValue = 1
        }
    }

    /// Fades the drop zone out and orders it off-screen.
    private func hideDropZone() {
        guard let dropZonePanel, isDropZoneShown else { return }
        isDropZoneShown = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            dropZonePanel.animator().alphaValue = 0
        } completionHandler: { [weak dropZonePanel] in
            dropZonePanel?.orderOut(nil)
        }
    }

    // MARK: - State observation

    /// Drives the bar from voice activity. Voice state sets the left-flank label
    /// and expands/collapses the panel; the mic and playback level publishers feed
    /// the right-flank waveform (each only while its state is active); tool-call
    /// activity drives the left-flank spinner. The initial `.idle` emission is a
    /// harmless no-op.
    private func observeVoiceState() {
        companionManager.$voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleVoiceStateChange(state)
            }
            .store(in: &cancellables)

        // Mic input level drives the waveform while listening.
        companionManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self, self.companionManager.voiceState == .listening else { return }
                self.viewModel.waveformLevel = level
            }
            .store(in: &cancellables)

        // Model playback level drives the waveform while speaking. This output
        // level is already wired; Session D layers the narration text on top.
        realtimeClient.$playbackAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self, self.companionManager.voiceState == .responding else { return }
                self.viewModel.waveformLevel = CGFloat(level)
            }
            .store(in: &cancellables)

        // Tool narration (Session D) overrides the left-flank label while a tool
        // runs; it falls back to the voice-state label when nil.
        realtimeClient.$currentActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshActivityText() }
            .store(in: &cancellables)

        // Tool-call activity drives the left-flank spinner glyph (from
        // RealtimeClient, which holds the spinner through the brief "✓" tail).
        realtimeClient.$isToolActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.viewModel.isToolActive = active
            }
            .store(in: &cancellables)
    }

    /// Picks the left-flank label: the model's tool narration when one is in
    /// flight, otherwise the plain voice-state word (Session C behavior).
    private func refreshActivityText() {
        if let activity = realtimeClient.currentActivity {
            viewModel.activityText = activity
        } else {
            viewModel.activityText = Self.activityText(for: companionManager.voiceState)
        }
    }

    /// Applies a new voice state: sets the activity label, expands or collapses
    /// the panel, and starts/stops the synthetic "thinking" waveform pulse.
    private func handleVoiceStateChange(_ state: CompanionVoiceState) {
        // Tool narration takes precedence over the state word when present.
        refreshActivityText()

        if state == .idle {
            collapse()
        } else {
            expand()
        }

        // While thinking there's no real audio signal, so synthesize a gentle
        // idle pulse. Listening/speaking are driven by their level publishers.
        if state == .processing {
            startThinkingPulse()
        } else {
            stopThinkingPulse()
        }

        // Clear the level at idle so a stale value doesn't linger into the next turn.
        if state == .idle {
            viewModel.waveformLevel = 0
        }
    }

    /// The left-flank label for each voice state. Empty at idle so the flank
    /// collapses to zero width.
    private static func activityText(for state: CompanionVoiceState) -> String {
        switch state {
        case .idle:       return ""
        case .listening:  return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    /// Starts a gentle 0.1s waveform oscillation used while thinking, since that
    /// state has no real audio level to visualize.
    private func startThinkingPulse() {
        stopThinkingPulse()
        thinkingPulsePhase = 0
        thinkingPulseCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.thinkingPulsePhase += 0.1
                // Breathe between ~0.2 and ~0.5 so the bars shimmer softly.
                self.viewModel.waveformLevel = 0.35 + 0.15 * CGFloat(sin(self.thinkingPulsePhase * .pi * 2))
            }
    }

    private func stopThinkingPulse() {
        thinkingPulseCancellable?.cancel()
        thinkingPulseCancellable = nil
    }

    // MARK: - Panel lifecycle

    /// Creates the bar panel (at idle) and the hidden history panel beneath it.
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
        expandedFrame = expandedBarFrame(idleFrame: idleFrame, screen: screen, geometry: geometry)

        // ── Bar panel ───────────────────────────────────────────────────────
        // The notch hosting view is wrapped in a DragDetectionView (the panel's
        // content view) so file drags are detected over the notch while the hosted
        // SwiftUI view still receives hover/click for the history panel.
        let barPanel = NotchBarPanel(contentRect: idleFrame)
        let barHosting = NSHostingView(rootView: NotchBarView(
            viewModel: viewModel,
            barHeight: geometry.barHeight,
            onHoverChange: { [weak self] hovering in self?.handleBarHover(hovering) },
            onTap: { [weak self] in self?.toggleHistoryPanel() }
        ))
        let barDragDetection = DragDetectionView(frame: NSRect(origin: .zero, size: idleFrame.size))
        barDragDetection.autoresizingMask = [.width, .height]
        barHosting.frame = barDragDetection.bounds
        barHosting.autoresizingMask = [.width, .height]
        barDragDetection.addSubview(barHosting)
        barDragDetection.onDragEntered = { [weak self] in self?.handleDragEntered(overZone: false) }
        barDragDetection.onDragExited = { [weak self] in self?.handleDragExited(overZone: false) }
        barDragDetection.onPerformDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
        barPanel.contentView = barDragDetection
        barPanel.setFrame(idleFrame, display: true)
        barPanel.orderFrontRegardless()
        self.panel = barPanel

        // ── History panel (hidden) ──────────────────────────────────────────
        // Width-matched to the idle bar initially; recomputed live on show so it
        // tracks the bar's current (idle or expanded) width.
        historyPanelFrame = currentHistoryPanelFrame()
        let historyPanel = HistoryPanel(contentRect: historyPanelFrame)
        historyPanel.alphaValue = 0
        let historyHosting = NSHostingView(rootView: HistoryPanelView(
            companionManager: companionManager,
            onHoverChange: { [weak self] hovering in self?.handleHistoryPanelHover(hovering) }
        ))
        historyHosting.frame = NSRect(origin: .zero, size: historyPanelFrame.size)
        historyHosting.autoresizingMask = [.width, .height]
        historyPanel.contentView = historyHosting
        historyPanel.setFrame(historyPanelFrame, display: false)
        self.historyPanel = historyPanel

        // ── Drop zone panel (hidden; appears only during a file drag) ────────
        // Its content view is also a DragDetectionView so dropping onto the zone
        // itself (not just the notch) works and keeps the drag alive.
        dropZonePanelFrame = currentDropZoneFrame()
        let dropZonePanel = DropZonePanel(contentRect: dropZonePanelFrame)
        dropZonePanel.alphaValue = 0
        let dropZoneDetection = DragDetectionView(frame: NSRect(origin: .zero, size: dropZonePanelFrame.size))
        dropZoneDetection.autoresizingMask = [.width, .height]
        let dropZoneHosting = NSHostingView(rootView: DropZoneView())
        dropZoneHosting.frame = dropZoneDetection.bounds
        dropZoneHosting.autoresizingMask = [.width, .height]
        dropZoneDetection.addSubview(dropZoneHosting)
        dropZoneDetection.onDragEntered = { [weak self] in self?.handleDragEntered(overZone: true) }
        dropZoneDetection.onDragExited = { [weak self] in self?.handleDragExited(overZone: true) }
        dropZoneDetection.onPerformDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
        dropZonePanel.contentView = dropZoneDetection
        dropZonePanel.setFrame(dropZonePanelFrame, display: false)
        self.dropZonePanel = dropZonePanel

        print("🪟 NotchPanel created — hasNotch=\(geometry.hasNotch), idleFrame=\(idleFrame), historyFrame=\(historyPanelFrame)")
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

    /// Builds the expanded bar frame, anchored to the notch's real center: it
    /// grows out of the idle notch to the left and right, capping each side's
    /// growth at that side's menu-bar auxiliary area width minus a small margin.
    /// Left and right growth are independent, so the expansion may be asymmetric
    /// when the two sides differ in width. On non-notch displays (no auxiliary
    /// areas) it falls back to the original centered expanded bar.
    private func expandedBarFrame(idleFrame: NSRect, screen: NSScreen, geometry: NotchGeometry) -> NSRect {
        guard geometry.hasNotch,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return barFrame(width: Self.expandedWidth, panelHeight: idleFrame.height, screen: screen)
        }

        let sideMargin: CGFloat = 8
        // Each side would grow by half the total expansion to reach expandedWidth,
        // but is capped at how much room that side's auxiliary area actually has.
        let desiredGrowthPerSide = max(0, (Self.expandedWidth - idleFrame.width) / 2)
        let leftGrowth = min(desiredGrowthPerSide, max(0, leftArea.width - sideMargin))
        let rightGrowth = min(desiredGrowthPerSide, max(0, rightArea.width - sideMargin))

        return NSRect(
            x: idleFrame.minX - leftGrowth,
            y: idleFrame.minY,
            width: idleFrame.width + leftGrowth + rightGrowth,
            height: idleFrame.height
        )
    }
}
