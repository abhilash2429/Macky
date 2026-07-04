//
//  SubAgentProgressController.swift
//  leanring-buddy
//
//  Separate right-side progress surface, intentionally away from the notch UI.
//

import AppKit
import SwiftUI
import Combine

final class SubAgentProgressPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubAgentProgressController: ObservableObject {
    @Published var state = SubAgentProgressState()

    private var panel: SubAgentProgressPanel?
    var onCancel: (() -> Void)?

    func show(taskTitle: String = "Visual guidance", agentName: String = "Visual Canvas Agent", currentStep: String = "Preparing guide") {
        state = SubAgentProgressState(
            isVisible: true,
            isExpanded: state.isExpanded,
            taskTitle: taskTitle,
            agentName: agentName,
            currentStep: currentStep,
            completedSteps: []
        )
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func markCompleted(_ step: String, next: String) {
        // Tool callbacks can arrive during the progress view's first render. Defer
        // this cosmetic update one run-loop tick so SwiftUI never sees a publish from
        // inside its own update pass.
        Task { @MainActor [weak self] in
            guard let self, self.state.isVisible else { return }
            var nextState = self.state
            if !nextState.completedSteps.contains(step) {
                nextState.completedSteps.append(step)
            }
            nextState.currentStep = next
            self.state = nextState
        }
    }

    func hide() {
        state = SubAgentProgressState()
        panel?.orderOut(nil)
    }

    func toggleExpanded() {
        var nextState = state
        nextState.isExpanded.toggle()
        state = nextState
        positionPanel()
    }

    func cancelFromView() {
        onCancel?()
        hide()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: 280, height: 180)
        let panel = SubAgentProgressPanel(contentRect: rect)
        let hosting = NSHostingView(rootView: SubAgentProgressRootView(controller: self))
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: rect)
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = state.isExpanded ? CGSize(width: 280, height: 210) : CGSize(width: 54, height: 54)
        let x = screen.frame.maxX - size.width - 24
        let y = screen.frame.midY - size.height / 2
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true, animate: true)
    }
}

private struct SubAgentProgressRootView: View {
    @ObservedObject var controller: SubAgentProgressController

    var body: some View {
        SubAgentProgressView(
            state: controller.state,
            onToggleExpanded: { controller.toggleExpanded() },
            onCancel: { controller.cancelFromView() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
