//
//  ThinkingIndicatorView.swift
//  leanring-buddy
//
//  A slow three-dot pulse shown in the notch bar's right zone while the model is
//  "thinking" (processing). The dots brighten out of phase with each other,
//  giving a gentle traveling-pulse feel.
//

import SwiftUI

struct ThinkingIndicatorView: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * pulse(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    /// A 0–1 brightness for the dot at `index`, offset so the three dots pulse out
    /// of phase.
    private func pulse(for index: Int) -> Double {
        let offset = Double(index) / 3.0
        return abs(sin((phase + offset) * .pi))
    }
}
