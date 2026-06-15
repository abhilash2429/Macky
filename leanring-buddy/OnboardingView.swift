//
//  OnboardingView.swift
//  leanring-buddy
//
//  Step-by-step first-run UI (Milestone 15). Presents one permission/connection
//  step at a time inside the onboarding panel, reusing the design system and the
//  embeddable HotkeySettingsView for the push-to-talk step.
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var manager: OnboardingManager
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            stepContent
            Spacer(minLength: 0)
            footer
        }
        .padding(DS.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if manager.currentStep != .done {
                Text("Step \(manager.currentStep.displayIndex) of \(OnboardingManager.Step.workingStepCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Text(title(for: manager.currentStep))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch manager.currentStep {
        case .hotkey:
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(description(for: .hotkey))
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HotkeySettingsView(companionManager: companionManager)
                    .padding(DS.Spacing.md)
                    .background(DS.Colors.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
            }
        case .done:
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(DS.Colors.success)
                Text(description(for: .done))
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: icon(for: manager.currentStep))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                        .frame(width: 22)
                    statusPill(for: manager.currentStep)
                }
                Text(description(for: manager.currentStep))
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if manager.currentStep == .screenRecording {
                    Text("macOS may require you to restart Speed before screen recording takes effect.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func statusPill(for step: OnboardingManager.Step) -> some View {
        let status = manager.status(for: step)
        let (label, color): (String, Color) = {
            switch status {
            case .pending: return ("Not set", DS.Colors.textTertiary)
            case .inProgress: return ("Waiting…", DS.Colors.textSecondary)
            case .granted: return ("Granted", DS.Colors.success)
            case .denied: return ("Denied", DS.Colors.destructiveText)
            case .skipped: return ("Skipped", DS.Colors.textSecondary)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
    }

    // MARK: - Footer (actions)

    @ViewBuilder
    private var footer: some View {
        let step = manager.currentStep
        VStack(spacing: DS.Spacing.sm) {
            Button(action: { manager.performAction(for: step) }) {
                Text(primaryActionLabel(for: step))
            }
            .dsPrimaryButtonStyle(isFullWidth: true)
            .pointerCursor()

            if step.isSkippable {
                Button(action: { manager.skipCurrentStep() }) {
                    Text("Skip")
                }
                .dsTextButtonStyle(fontSize: 13)
                .pointerCursor()
            }
        }
    }

    private func primaryActionLabel(for step: OnboardingManager.Step) -> String {
        switch step {
        case .microphone, .screenRecording, .accessibility, .calendar, .reminders:
            return manager.status(for: step) == .granted ? "Continue" : "Grant Access"
        case .slack, .gmail, .spotify, .hotkey:
            return "Continue"
        case .done:
            return "Finish"
        }
    }

    // MARK: - Copy

    private func title(for step: OnboardingManager.Step) -> String {
        switch step {
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .slack: return "Connect Slack"
        case .gmail: return "Connect Gmail"
        case .spotify: return "Connect Spotify"
        case .hotkey: return "Set Your Hotkey"
        case .done: return "You're all set"
        }
    }

    private func description(for step: OnboardingManager.Step) -> String {
        switch step {
        case .microphone:
            return "Speed needs your microphone so you can talk to it."
        case .screenRecording:
            return "Screen recording lets Speed see your screen and help with what you're looking at."
        case .accessibility:
            return "Accessibility access lets Speed control your cursor and interact with apps on your behalf."
        case .calendar:
            return "Calendar access lets Speed read your schedule and create events when you ask."
        case .reminders:
            return "Reminders access lets Speed create reminders when you ask."
        case .slack:
            return "You can connect Slack anytime by asking Speed to do something in Slack — it'll walk you through signing in. Skip for now if you'd rather set it up later."
        case .gmail:
            return "You can connect Gmail anytime by asking Speed to read or send mail — it'll walk you through signing in. Skip for now if you'd rather set it up later."
        case .spotify:
            return "You can connect Spotify anytime by asking Speed to play something — it'll walk you through signing in. Skip for now if you'd rather set it up later."
        case .hotkey:
            return "Pick a push-to-talk shortcut. Hold it to talk to Speed from anywhere. You can change this later or skip for now."
        case .done:
            return "Speed is ready to go. You can manage permissions and connections anytime from the menu bar."
        }
    }

    private func icon(for step: OnboardingManager.Step) -> String {
        switch step {
        case .microphone: return "mic"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .slack: return "number"
        case .gmail: return "envelope"
        case .spotify: return "music.note"
        case .hotkey: return "keyboard"
        case .done: return "checkmark.circle.fill"
        }
    }
}
