//
//  HotkeySettingsView.swift
//  leanring-buddy
//
//  Inline push-to-talk shortcut recorder for the notch panel. Shows the
//  current modifier-only combo and lets the user record a new one. The capture
//  saves to UserDefaults (via HotkeyConfiguration) and tells the running global
//  monitor to re-read it, so the new shortcut works immediately and after relaunch.
//

import AppKit
import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var isRecording = false
    /// The combo shown in the idle row. Seeded from the live monitor and updated
    /// locally on save so the row reflects the new shortcut without a republish.
    @State private var displayConfig: HotkeyConfiguration
    /// Largest set of modifiers held during the current recording session.
    @State private var capturedModifiers: NSEvent.ModifierFlags = []
    /// The local NSEvent monitor active only while recording.
    @State private var flagsMonitor: Any?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _displayConfig = State(
            initialValue: companionManager.globalPushToTalkShortcutMonitor.currentHotkey
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Push-to-talk")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                if isRecording {
                    recordingIndicator
                } else {
                    changeButton
                }
            }

            if isRecording {
                recordingHint
            }
        }
        .padding(.vertical, 4)
        .onDisappear(perform: stopRecording)
    }

    // MARK: - Idle

    private var changeButton: some View {
        Button(action: startRecording) {
            HStack(spacing: 6) {
                Text(displayConfig.displayText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Recording

    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Text(capturedModifiers.isEmpty ? "Press your shortcut…" : previewText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(capturedModifiers.isEmpty ? DS.Colors.textTertiary : DS.Colors.accentText)

            Button(action: cancelRecording) {
                Text("Cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var recordingHint: some View {
        Text("Hold a modifier combo (e.g. ctrl + option), then release to save.")
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var previewText: String {
        HotkeyConfiguration(modifierFlags: capturedModifiers).displayText
    }

    // MARK: - Capture lifecycle

    private func startRecording() {
        guard flagsMonitor == nil else { return }
        capturedModifiers = []
        isRecording = true

        // Local monitor: fires while the panel is the key window. We watch only
        // modifier transitions since Speed supports modifier-only shortcuts.
        // Returning nil swallows the event so it doesn't reach the panel's own
        // controls while the user is recording.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handleFlagsChanged(event)
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if activeModifiers.isEmpty {
            // All keys released — commit whatever combo was held.
            commitRecording()
        } else {
            // Accumulate so adding keys one-by-one still captures the full combo.
            capturedModifiers.formUnion(activeModifiers)
        }
    }

    private func commitRecording() {
        let captured = capturedModifiers
        stopRecording()

        // Empty captures are impossible to reach here (we only commit on release
        // after a non-empty set), but guard anyway — an empty combo would match
        // every keystroke.
        guard !captured.isEmpty else { return }

        let newConfiguration = HotkeyConfiguration(modifierFlags: captured)
        guard !newConfiguration.modifierFlags.isEmpty else { return }

        newConfiguration.save()
        displayConfig = newConfiguration
        companionManager.globalPushToTalkShortcutMonitor.refreshHotkey()
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        capturedModifiers = []
        isRecording = false
    }
}
