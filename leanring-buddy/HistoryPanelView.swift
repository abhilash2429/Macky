//
//  HistoryPanelView.swift
//  leanring-buddy
//
//  The panel that grows straight down from the notch bar on hover/click, hosted
//  in a HistoryPanel owned by NotchPanelController. Shows the activity history
//  log (CompanionManager.historyLog), most-recent-first.
//
//  Flat top corners (flush with the notch bar's bottom edge) and rounded bottom
//  corners; the fill is the same solid black as the bar so the two read as one
//  continuous surface with no seam. It never shows tool-execution status — that
//  lives in the notch bar itself.
//

import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Reports hover enter/exit so the controller can manage the dismiss timer.
    var onHoverChange: (Bool) -> Void = { _ in }

    /// Flat top, rounded bottom — matching the notch bar's bottom corner radius
    /// (reused from NotchConstants, not duplicated).
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: NotchConstants.openedCornerRadius.bottom,
            bottomTrailingRadius: NotchConstants.openedCornerRadius.bottom,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            // Same solid black as the notch bar so the panel looks like a
            // continuous extension of it — no visual seam at the top edge.
            Color.black
            content
        }
        .clipShape(panelShape)
        .onHover { onHoverChange($0) }
    }

    @ViewBuilder
    private var content: some View {
        if companionManager.historyLog.isEmpty {
            Text("No activity yet.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // historyLog is appended chronologically, so reverse for
                    // most-recent-first.
                    ForEach(companionManager.historyLog.reversed()) { entry in
                        HistoryRow(entry: entry)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

/// A single history row: timestamp (dim, monospaced) + the entry summary.
private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .frame(width: 38, alignment: .leading)

            Text(entry.summary)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
