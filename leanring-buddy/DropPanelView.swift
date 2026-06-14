//
//  DropPanelView.swift
//  leanring-buddy
//
//  The panel that slides down from under the notch bar on hover/click. Shows the
//  recent interaction history and a file-drop zone for attaching context to the
//  next voice turn. Hosted in a second NSPanel owned by NotchPanelController.
//
//  Top corners are flat (flush with the notch bar's bottom edge); bottom corners
//  are rounded. The background is a translucent HUD blur.
//

import SwiftUI

/// Shared rounded-rect shape for the drop panel: flat top, rounded bottom.
private let dropPanelShape = UnevenRoundedRectangle(
    topLeadingRadius: 0,
    bottomLeadingRadius: 12,
    bottomTrailingRadius: 12,
    topTrailingRadius: 0,
    style: .continuous
)

/// SwiftUI wrapper for NSVisualEffectView, used as the panel's translucent
/// background.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct DropPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Reports hover enter/exit so the controller can manage the dismiss timer.
    var onHoverChange: (Bool) -> Void = { _ in }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(dropPanelShape)

            VStack(spacing: 0) {
                historySection
                Divider()
                    .opacity(0.3)
                FileDropZone(companionManager: companionManager)
            }
        }
        .clipShape(dropPanelShape)
        .onHover { onHoverChange($0) }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("recent")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if companionManager.recentInteractions.isEmpty {
                Text("no recent interactions yet")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(companionManager.recentInteractions) { interaction in
                            InteractionRow(interaction: interaction)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single history row: timestamp, user phrase (bright), model summary (dim).
private struct InteractionRow: View {
    let interaction: Interaction

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(interaction.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .frame(width: 40, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if !interaction.userPhrase.isEmpty {
                    Text(interaction.userPhrase)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                }
                if !interaction.modelSummary.isEmpty {
                    Text(interaction.modelSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
