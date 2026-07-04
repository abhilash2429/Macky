//
//  SubAgentProgressView.swift
//  leanring-buddy
//
//  Minimal right-side progress surface for specialist work. Milestone 1 uses it
//  for visual-guidance preparation/execution only; durable backend tasks come later.
//

import SwiftUI

struct SubAgentProgressState: Equatable {
    var isVisible: Bool = false
    var isExpanded: Bool = false
    var taskTitle: String = "Visual guidance"
    var agentName: String = "Visual Canvas Agent"
    var currentStep: String = "Preparing guide"
    var completedSteps: [String] = []
}

struct SubAgentProgressView: View {
    let state: SubAgentProgressState
    let onToggleExpanded: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if state.isExpanded {
            expandedPanel
        } else {
            collapsedOrb
        }
    }

    private var collapsedOrb: some View {
        Button(action: onToggleExpanded) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.70))
                    .frame(width: 54, height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                VStack(spacing: 4) {
                    MackyGlyphLogo(size: 20, glow: true)
                    DotMatrixLoaderView()
                        .frame(width: 22, height: 8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                MackyGlyphLogo(size: 22, glow: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.taskTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(state.agentName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.completedSteps, id: \.self) { step in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.success)
                        Text(step)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                }
                HStack(spacing: 7) {
                    DotMatrixLoaderView()
                        .frame(width: 24, height: 10)
                    Text(state.currentStep)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18)
    }
}
