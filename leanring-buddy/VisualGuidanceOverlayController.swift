//
//  VisualGuidanceOverlayController.swift
//  leanring-buddy
//
//  Owns Macky's transparent full-screen teaching overlay, separate from the notch UI.
//

import AppKit
import Combine
import SwiftUI

private extension CGRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}

final class VisualGuidanceOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VisualGuidanceOverlayController: ObservableObject {
    @Published var currentStep: VisualGuidanceStep?
    @Published var sourceSize: CGSize = .zero

    private var panel: VisualGuidanceOverlayPanel?
    private var sequenceTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var guardedBundleIdentifier: String?

    var onSequenceCompleted: (() -> Void)?

    func run(sequence: VisualGuidanceSequence) {
        do {
            let validated = try sequence.validated()
            guard let screen = screen(for: validated) ?? NSScreen.main else { return }
            sourceSize = validated.coordinateSpace?.cgSize ?? screen.frame.size
            print("🧪 VisualGuidanceOverlayDiagnostics screenFrame=\(screen.frame.debugDescription) backingScale=\(screen.backingScaleFactor) sourceSize=\(sourceSize.debugDescription) displayFrame=\(validated.displayFrame?.cgRect.debugDescription ?? \"nil\") steps=\(validated.steps.count)")
            ensurePanel(on: screen)
            guardedBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            observeAppSwitches()
            panel?.orderFrontRegardless()

            sequenceTask?.cancel()
            sequenceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for step in validated.steps {
                    guard !Task.isCancelled else { return }
                    self.currentStep = step
                    if let cursor = step.cursor {
                        switch cursor.type {
                        case .move:
                            _ = try? await CursorGuidanceIntegration.move(to: cursor, coordinateSpace: validated.coordinateSpace)
                        case .click:
                            _ = try? await CursorGuidanceIntegration.click(at: cursor, coordinateSpace: validated.coordinateSpace)
                        }
                    }
                    try? await Task.sleep(nanoseconds: step.displayDurationNanoseconds)
                    if step.clearBeforeNext ?? true {
                        self.currentStep = nil
                        try? await Task.sleep(nanoseconds: 140_000_000)
                    }
                }
                self.clear()
                self.onSequenceCompleted?()
            }
        } catch {
            print("⚠️ VisualGuidanceOverlay: invalid sequence: \(error.localizedDescription)")
        }
    }

    func clear() {
        sequenceTask?.cancel()
        sequenceTask = nil
        currentStep = nil
        panel?.orderOut(nil)
        stopObservingAppSwitches()
        guardedBundleIdentifier = nil
    }

    private func screen(for sequence: VisualGuidanceSequence) -> NSScreen? {
        guard let displayFrame = sequence.displayFrame else { return nil }
        if let displayID = displayFrame.displayID,
           let screen = NSScreen.screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
           }) {
            return screen
        }

        let targetFrame = displayFrame.cgRect
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(targetFrame).area < rhs.frame.intersection(targetFrame).area
        }
    }

    private func ensurePanel(on screen: NSScreen) {
        if let panel {
            panel.setFrame(screen.frame, display: true)
            return
        }

        let panel = VisualGuidanceOverlayPanel(contentRect: screen.frame)
        let hosting = NSHostingView(rootView: VisualGuidanceOverlayRootView(controller: self))
        hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
    }

    private func observeAppSwitches() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self else { return }
                guard let guardedBundleIdentifier = self.guardedBundleIdentifier else { return }
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
                      app.bundleIdentifier != guardedBundleIdentifier else { return }
                self.clear()
            }
        }
    }

    private func stopObservingAppSwitches() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}

private struct VisualGuidanceOverlayRootView: View {
    @ObservedObject var controller: VisualGuidanceOverlayController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let step = controller.currentStep {
                VisualGuidanceOverlayView(step: step, sourceSize: controller.sourceSize)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .allowsHitTesting(false)
    }
}
