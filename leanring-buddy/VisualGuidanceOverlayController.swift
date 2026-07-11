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
    private var presentationGeneration = 0
    private var activationObserver: NSObjectProtocol?
    private var guardedBundleIdentifier: String?

    var onSequenceCompleted: (() -> Void)?

    func run(presentation: VisualGuidancePresentation) {
        clear()
        do {
            let validated = try presentation.sequence.validated()
            if let expectedBundleIdentifier = presentation.sourceApplicationBundleIdentifier,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expectedBundleIdentifier {
                print("⚠️ VisualGuidanceOverlay: source application changed before presentation")
                onSequenceCompleted?()
                return
            }
            guard let screen = screen(for: validated) else {
                onSequenceCompleted?()
                return
            }

            let generation = presentationGeneration
            sourceSize = validated.coordinateSpace?.cgSize ?? screen.frame.size
            print(
                "🧪 VisualGuidanceOverlayDiagnostics " +
                "screenFrame=\(screen.frame.debugDescription) " +
                "backingScale=\(screen.backingScaleFactor) " +
                "sourceSize=\(sourceSize.debugDescription) " +
                "displayFrame=\(validated.displayFrame?.cgRect.debugDescription ?? "nil") " +
                "steps=\(validated.steps.count)"
            )
            ensurePanel(on: screen)
            guardedBundleIdentifier = presentation.sourceApplicationBundleIdentifier
                ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            observeAppSwitches()
            panel?.orderFrontRegardless()

            sequenceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var accumulatedCanvas: [CanvasCommand] = []
                var shouldClearBeforeStep = true

                for step in validated.steps {
                    guard !Task.isCancelled, self.presentationGeneration == generation else { return }
                    if shouldClearBeforeStep {
                        accumulatedCanvas = []
                    }
                    accumulatedCanvas.append(contentsOf: step.canvas)

                    let stepStart = Date()
                    self.currentStep = self.renderedStep(
                        from: step,
                        canvas: accumulatedCanvas,
                        showCursorLabel: false
                    )
                    if let cursor = step.cursor {
                        do {
                            _ = try await CursorControlIntegration.move(
                                to: cursor,
                                coordinateSpace: validated.coordinateSpace,
                                expectedApplicationBundleIdentifier: presentation.sourceApplicationBundleIdentifier
                            )
                        } catch is CancellationError {
                            return
                        } catch {
                            print("⚠️ VisualGuidanceOverlay: cursor move failed: \(error.localizedDescription)")
                        }
                        guard !Task.isCancelled, self.presentationGeneration == generation else { return }
                        self.currentStep = self.renderedStep(
                            from: step,
                            canvas: accumulatedCanvas,
                            showCursorLabel: true
                        )
                    }

                    let elapsedNanoseconds = UInt64(max(0, Date().timeIntervalSince(stepStart)) * 1_000_000_000)
                    let remainingNanoseconds = step.displayDurationNanoseconds > elapsedNanoseconds
                        ? step.displayDurationNanoseconds - elapsedNanoseconds
                        : 0
                    if remainingNanoseconds > 0 {
                        do {
                            try await Task.sleep(nanoseconds: remainingNanoseconds)
                        } catch {
                            return
                        }
                    }
                    shouldClearBeforeStep = step.clearBeforeNext ?? true
                }
                self.finishPresentation(generation: generation, notifyCompletion: true)
            }
        } catch {
            print("⚠️ VisualGuidanceOverlay: invalid sequence: \(error.localizedDescription)")
            onSequenceCompleted?()
        }
    }

    func showCursorLabel(_ presentation: CursorLabelPresentation) {
        clear()
        let generation = presentationGeneration

        sourceSize = presentation.coordinateSpace.cgSize
        let sequence = VisualGuidanceSequence(
            title: nil,
            sourceWidth: presentation.coordinateSpace.width,
            sourceHeight: presentation.coordinateSpace.height,
            displayFrame: presentation.coordinateSpace.displayFrame,
            steps: []
        )
        guard let screen = screen(for: sequence) else { return }
        ensurePanel(on: screen)
        guardedBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observeAppSwitches()
        panel?.orderFrontRegardless()
        currentStep = VisualGuidanceStep(
            narrationCue: nil,
            durationMs: nil,
            clearBeforeNext: true,
            canvas: [],
            cursor: presentation.command
        )

        sequenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: presentation.displayDurationNanoseconds)
            } catch {
                return
            }
            self?.finishPresentation(generation: generation, notifyCompletion: false)
        }
    }

    func clear() {
        presentationGeneration += 1
        sequenceTask?.cancel()
        sequenceTask = nil
        currentStep = nil
        panel?.orderOut(nil)
        stopObservingAppSwitches()
        guardedBundleIdentifier = nil
    }

    private func renderedStep(
        from step: VisualGuidanceStep,
        canvas: [CanvasCommand],
        showCursorLabel: Bool
    ) -> VisualGuidanceStep {
        let cursor = step.cursor.map { cursor in
            CursorCommand(
                type: cursor.type,
                x: cursor.x,
                y: cursor.y,
                durationMs: cursor.durationMs,
                label: showCursorLabel ? cursor.label : nil,
                labelPlacement: cursor.labelPlacement
            )
        }
        return VisualGuidanceStep(
            narrationCue: step.narrationCue,
            durationMs: step.durationMs,
            clearBeforeNext: step.clearBeforeNext,
            canvas: canvas,
            cursor: cursor
        )
    }

    private func finishPresentation(generation: Int, notifyCompletion: Bool) {
        guard presentationGeneration == generation else { return }
        presentationGeneration += 1
        sequenceTask?.cancel()
        sequenceTask = nil
        currentStep = nil
        panel?.orderOut(nil)
        stopObservingAppSwitches()
        guardedBundleIdentifier = nil
        if notifyCompletion {
            onSequenceCompleted?()
        }
    }

    private func screen(for sequence: VisualGuidanceSequence) -> NSScreen? {
        guard let displayFrame = sequence.displayFrame else { return NSScreen.main }
        if let displayID = displayFrame.displayID,
           let screen = NSScreen.screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
           }) {
            return screen
        }

        let targetFrame = displayFrame.cgRect
        guard let bestMatch = NSScreen.screens.max(by: { lhs, rhs in
            lhs.frame.intersection(targetFrame).area < rhs.frame.intersection(targetFrame).area
        }) else { return nil }
        return bestMatch.frame.intersection(targetFrame).area > 0 ? bestMatch : nil
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
                let generation = self.presentationGeneration
                self.finishPresentation(generation: generation, notifyCompletion: true)
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
