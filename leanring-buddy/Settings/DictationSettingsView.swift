//
//  DictationSettingsView.swift
//  leanring-buddy
//

import SwiftUI

struct DictationSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var coordinator: DictationCoordinator

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _coordinator = ObservedObject(wrappedValue: companionManager.dictationCoordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation")
                        .font(.system(size: DS.PanelTypography.size(13), weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Hold ctrl + fn. Macky inserts one final result only after the original field is revalidated.")
                        .font(.system(size: DS.PanelTypography.size(10)))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Style", selection: $coordinator.formattingMode) {
                ForEach(DictationFormattingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(coordinator.formattingMode.detail)
                .font(.system(size: DS.PanelTypography.size(10)))
                .foregroundColor(DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 5) {
                Text("Keyterms")
                    .font(.system(size: DS.PanelTypography.size(11), weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                TextEditor(text: $coordinator.glossaryText)
                    .font(.system(size: DS.PanelTypography.size(11)))
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(height: 58)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                Text("Names, domains, companies, and code identifiers. One per line or comma-separated; up to 100 terms.")
                    .font(.system(size: DS.PanelTypography.size(10)))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text("Azure gpt-realtime-2.1-mini receives held microphone audio, this glossary, and a broad category derived from the app that was frontmost when dictation began. Smart uses that category for app-aware polish; Clean and Smart can format clearly dictated items as numbered lists. Macky never sends focused-field text, selections, titles, URLs, recipients, or page contents.")
                .font(.system(size: DS.PanelTypography.size(10)))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
    }
}
