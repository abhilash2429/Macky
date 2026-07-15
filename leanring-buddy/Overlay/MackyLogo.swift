//
//  MackyLogo.swift
//  leanring-buddy
//
//  Filled Macky glyph logo used throughout the product UI.
//

import SwiftUI

// MARK: - Filled glyph logo (brand chip)

/// The modern Macky brand mark: a filled, glowing blue rounded-square "face" with
/// two white eyes. This is the identity shown in the panel header, auth, settings,
/// and onboarding — anywhere the brand appears as a solid chip rather than the
/// thin outline. `size` is the rendered width of the rounded-square body; the soft
/// halo extends slightly beyond it. Set `glow: false` for tight, inline placements
/// (e.g. the compact header chip) where the halo would bleed into neighbors.
struct MackyGlyphLogo: View {
    var size: CGFloat
    var glow: Bool = true

    // Eye geometry as a fraction of the body size, tuned to match the brand mark:
    // two vertical ovals sitting just below center, insetting from the middle.
    private var eyeWidth: CGFloat { size * 0.17 }
    private var eyeHeight: CGFloat { size * 0.26 }
    private var eyeGap: CGFloat { size * 0.16 }
    private var eyeCenterY: CGFloat { size * 0.55 }

    private let bodyGradient = LinearGradient(
        colors: [Color(hex: "#7CC8FF"), Color(hex: "#3B9EFF")],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack {
            if glow {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(Color(hex: "#6FC0FF"))
                    .frame(width: size, height: size * 0.92)
                    .blur(radius: size * 0.34)
                    .opacity(0.85)
            }

            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(bodyGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: max(0.75, size * 0.02))
                )
                .frame(width: size, height: size * 0.92)
                .shadow(color: Color(hex: "#3B9EFF").opacity(glow ? 0.65 : 0.0), radius: glow ? size * 0.18 : 0)

            HStack(spacing: eyeGap) {
                eye
                eye
            }
            .offset(y: eyeCenterY - size * 0.46)
        }
        .frame(width: size * (glow ? 1.5 : 1.0), height: size * (glow ? 1.5 : 1.0))
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(Color.white)
            .frame(width: eyeWidth, height: eyeHeight)
    }
}
