//
//  ModelOutputCard.swift
//  leanring-buddy
//
//  Fills the open panel's content area when the model pushes a draft for review
//  (panelDisplayState == .modelOutput). A type badge, the draft text in a
//  scrollable inner area, and a fixed action bar: Discard, Edit, Approve.
//
//  Edit is intentionally disabled this session: the host NSPanel is
//  non-activating (canBecomeKey == false), so a SwiftUI TextEditor can't receive
//  typed keystrokes here. Inline editing returns with a focus-toggling panel
//  variant in a later session.
//

import SwiftUI

struct ModelOutputCard: View {
    let content: String
    let type: PanelOutputType
    @ObservedObject var companionManager: CompanionManager

    /// Cap the inner text height so the action bar stays visible; the text scrolls
    /// inside this when the draft is long.
    private let innerContentMaxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            badge

            ScrollView(.vertical, showsIndicators: true) {
                Text(content)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: innerContentMaxHeight)

            actionBar
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var badge: some View {
        Text(type.badgeLabel)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(DS.Colors.accentText)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(DS.Colors.accentSubtle))
    }

    private var actionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button("Discard") { companionManager.discardModelOutput() }
                .dsDestructiveButtonStyle()

            Spacer(minLength: DS.Spacing.sm)

            Button("Edit") {}
                .dsSecondaryButtonStyle(isFullWidth: false)
                .disabled(true)
                .help("Editing coming soon")

            Button("Approve") { companionManager.executePendingModelOutput() }
                .dsPrimaryButtonStyle(isFullWidth: false)
        }
    }
}
