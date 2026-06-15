//
//  OnboardingManager.swift
//  leanring-buddy
//
//  First-run onboarding (Milestone 15). After the user's first successful
//  magic-link auth, this walks them through OS permissions and service
//  connections in a dedicated center-screen panel before they reach the notch UI.
//
//  Completion is tracked under the UserDefaults key "onboardingCompleted" — a
//  separate flag from CompanionManager.hasCompletedOnboarding (which gates the
//  cursor-overlay intro). Once "onboardingCompleted" is true the flow never shows
//  again, even on a fresh launch.
//

import AppKit
import AVFoundation
import Combine
import EventKit
import SwiftUI

/// Drives the step-by-step onboarding flow and owns its floating panel.
@MainActor
final class OnboardingManager: ObservableObject {
    /// The onboarding steps, in the exact order they're presented.
    enum Step: Int, CaseIterable {
        case microphone
        case screenRecording
        case accessibility
        case calendar
        case reminders
        case slack
        case gmail
        case spotify
        case hotkey
        case done

        /// 1-based position within the steps the user actively works through
        /// (everything except the final "done" confirmation).
        var displayIndex: Int { rawValue + 1 }

        /// Total number of working steps (excludes `.done`).
        static var workingStepCount: Int { allCases.count - 1 }

        /// Steps 6–9 (services + hotkey) can be skipped.
        var isSkippable: Bool {
            switch self {
            case .slack, .gmail, .spotify, .hotkey: return true
            default: return false
            }
        }
    }

    /// Per-step outcome, surfaced as a status pill in the UI.
    enum StepStatus {
        case pending
        case inProgress
        case granted
        case denied
        case skipped
    }

    @Published private(set) var currentStep: Step = .microphone
    @Published private(set) var statuses: [Step: StepStatus] = [:]

    /// Whether the permissions/services onboarding has been completed at least
    /// once. Read on launch to decide whether to show the flow at all.
    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingCompleted") }
    }

    /// Invoked once the user finishes (or the flow is otherwise dismissed) so the
    /// app delegate can tear down the panel and resume the normal launch UI.
    var onFinished: (() -> Void)?

    let companionManager: CompanionManager

    private let eventStore = EKEventStore()
    private var panel: NSPanel?
    private var permissionCancellables = Set<AnyCancellable>()

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        observePermissionFlags()
        seedInitialStatuses()
    }

    // MARK: - Panel lifecycle

    /// Builds and shows the centered onboarding panel. Keyable so the embedded
    /// HotkeySettingsView can record modifier combos via its local event monitor.
    func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(
            rootView: OnboardingView(manager: self, companionManager: companionManager)
        )

        let size = NSSize(width: 480, height: 560)
        let panel = OnboardingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Match the notch panel's level so onboarding floats above normal windows.
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        panel?.close()
        panel = nil
        permissionCancellables.removeAll()
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    /// Skips the current (skippable) step and moves on.
    func skipCurrentStep() {
        guard currentStep.isSkippable else { return }
        setStatus(.skipped, for: currentStep)
        advance()
    }

    /// Advances past a step the user has acknowledged (e.g. the service cards or
    /// the hotkey step once they're happy with their shortcut).
    func continueCurrentStep() {
        if statuses[currentStep] == nil || statuses[currentStep] == .pending {
            setStatus(.granted, for: currentStep)
        }
        advance()
    }

    /// Completes onboarding permanently and tears down the panel.
    func finish() {
        OnboardingManager.isComplete = true
        dismiss()
        onFinished?()
    }

    // MARK: - Step actions

    /// Runs the permission request / connection action for the current step.
    func performAction(for step: Step) {
        switch step {
        case .microphone:
            requestMicrophone()
        case .screenRecording:
            requestScreenRecording()
        case .accessibility:
            requestAccessibility()
        case .calendar:
            requestCalendar()
        case .reminders:
            requestReminders()
        case .slack, .gmail, .spotify:
            // Service connections are deferred to the in-app voice flow; the user
            // connects them later by asking the assistant. Treat the action as
            // acknowledgement and move on.
            continueCurrentStep()
        case .hotkey:
            continueCurrentStep()
        case .done:
            finish()
        }
    }

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setStatus(.granted, for: .microphone)
            advanceIfCurrent(.microphone)
        case .notDetermined:
            setStatus(.inProgress, for: .microphone)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.companionManager.refreshAllPermissions()
                    self.setStatus(granted ? .granted : .denied, for: .microphone)
                    if granted { self.advanceIfCurrent(.microphone) }
                }
            }
        default:
            // Already denied/restricted — send the user to System Settings.
            setStatus(.denied, for: .microphone)
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func requestScreenRecording() {
        // macOS only reflects a screen-recording grant after relaunch, so the UI
        // copy warns about that. The Combine observer flips the pill to granted if
        // the OS reports it during this session.
        setStatus(.inProgress, for: .screenRecording)
        let destination = WindowPositionManager.requestScreenRecordingPermission()
        if destination == .alreadyGranted {
            setStatus(.granted, for: .screenRecording)
            advanceIfCurrent(.screenRecording)
        }
    }

    private func requestAccessibility() {
        setStatus(.inProgress, for: .accessibility)
        let destination = WindowPositionManager.requestAccessibilityPermission()
        if destination == .alreadyGranted {
            setStatus(.granted, for: .accessibility)
            advanceIfCurrent(.accessibility)
        }
    }

    private func requestCalendar() {
        setStatus(.inProgress, for: .calendar)
        Task {
            let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
            setStatus(granted ? .granted : .denied, for: .calendar)
            if granted { advanceIfCurrent(.calendar) }
        }
    }

    private func requestReminders() {
        setStatus(.inProgress, for: .reminders)
        Task {
            let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
            setStatus(granted ? .granted : .denied, for: .reminders)
            if granted { advanceIfCurrent(.reminders) }
        }
    }

    private func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Status helpers

    func setStatus(_ status: StepStatus, for step: Step) {
        statuses[step] = status
    }

    func status(for step: Step) -> StepStatus {
        statuses[step] ?? .pending
    }

    /// Auto-advances only when the granted step is the one the user is currently
    /// on, so a late-arriving permission callback doesn't jump them around.
    private func advanceIfCurrent(_ step: Step) {
        guard currentStep == step else { return }
        advance()
    }

    /// Seeds statuses for permissions that may already be granted (e.g. on a
    /// re-run after the flag was reset) so the UI shows the real state up front.
    private func seedInitialStatuses() {
        if companionManager.hasMicrophonePermission { statuses[.microphone] = .granted }
        if companionManager.hasScreenRecordingPermission { statuses[.screenRecording] = .granted }
        if companionManager.hasAccessibilityPermission { statuses[.accessibility] = .granted }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            statuses[.calendar] = .granted
        }
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        if reminderStatus == .fullAccess || reminderStatus == .writeOnly {
            statuses[.reminders] = .granted
        }
    }

    /// Mirrors CompanionManager's live permission flags into step statuses so the
    /// pills update as the user grants access in System Settings (no own timer —
    /// CompanionManager already polls).
    private func observePermissionFlags() {
        companionManager.$hasMicrophonePermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                guard let self, granted else { return }
                self.setStatus(.granted, for: .microphone)
                self.advanceIfCurrent(.microphone)
            }
            .store(in: &permissionCancellables)

        companionManager.$hasScreenRecordingPermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                guard let self, granted else { return }
                self.setStatus(.granted, for: .screenRecording)
                self.advanceIfCurrent(.screenRecording)
            }
            .store(in: &permissionCancellables)

        companionManager.$hasAccessibilityPermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                guard let self, granted else { return }
                self.setStatus(.granted, for: .accessibility)
                self.advanceIfCurrent(.accessibility)
            }
            .store(in: &permissionCancellables)
    }
}

/// Borderless panel that can become key so the embedded hotkey recorder receives
/// keyboard events.
private final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
