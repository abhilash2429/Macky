//
//  PanelHeader.swift
//  leanring-buddy
//
//  The persistent header pinned to the top of the open notch panel, outside the
//  scroll area, so it never scrolls away. Left side shows the Speed wordmark (and
//  a back chevron when a sub-surface is showing); right side shows two icon
//  buttons that switch the panel to the connectors and settings surfaces.
//

import SwiftUI

struct PanelHeader: View {
    @ObservedObject var companionManager: CompanionManager
    /// Invoked by the back chevron — returns the panel to its idle dashboard.
    var onBack: () -> Void

    /// The back chevron only makes sense when we've navigated away from idle.
    private var showsBack: Bool {
        companionManager.panelDisplayState != .idle
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if showsBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .dsIconButtonStyle(size: 22, tooltip: "Back", tooltipAlignment: .leading)
                .transition(.opacity)
            }

            Text("Speed")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)

            Spacer(minLength: DS.Spacing.sm)

            Button { companionManager.panelDisplayState = .connectors } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
            }
            .dsIconButtonStyle(size: 24, tooltip: "Connectors", tooltipAlignment: .trailing)

            Button { companionManager.panelDisplayState = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .dsIconButtonStyle(size: 24, tooltip: "Settings", tooltipAlignment: .trailing)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .animation(.smooth(duration: 0.18), value: showsBack)
    }
}
