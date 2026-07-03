//
//  MackyLogo.swift
//  leanring-buddy
//
//  The official Macky identity, drawn natively from the brand SVG geometry
//  (viewBox 0 0 280 220): a MacBook-with-notch body outline, a top-center notch
//  tab, and two eyes.
//
//  Two flavors:
//    • `MackyLogoView`         — the standard static logo. Used everywhere the
//                                brand is shown at rest (panel header, settings,
//                                app icon rendering).
//    • `MackyAnimatedLogoView` — the same geometry with living eyes that blink,
//                                look around, wink, and squint. This dynamic
//                                version lives only in the notch.
//
//  Everything is authored in the 280×220 source space and uniformly scaled to
//  the requested size, so stroke weight and corner radii stay proportional.
//

import SwiftUI

// MARK: - Source geometry (matches the brand SVG)

private enum MackyGeometry {
    /// Native artboard the logo is authored in.
    static let artboard = CGSize(width: 280, height: 220)

    /// Body rounded-rect outline (stroke straddles this rect).
    static let bodyRect = CGRect(x: 15, y: 40, width: 250, height: 165)
    static let bodyCornerRadius: CGFloat = 30
    static let bodyStrokeWidth: CGFloat = 13

    /// Eyes — rounded squares, scaled vertically about their center.
    static let eyeSize: CGFloat = 55
    static let eyeCornerRadius: CGFloat = 12
    static let eyeCenterY: CGFloat = 130.5
    static let leftEyeCenterX: CGFloat = 61 + 55 / 2   // 88.5
    static let rightEyeCenterX: CGFloat = 164 + 55 / 2 // 191.5
}

// MARK: - Shapes

/// The rounded MacBook body outline (stroked, transparent interior so the
/// background reads through it just like the brand mark).
private struct MackyBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: MackyGeometry.bodyRect,
            cornerRadius: MackyGeometry.bodyCornerRadius
        )
    }
}

/// The small notch tab hanging from the top-center of the body.
private struct MackyNotchTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 95, y: 40))
        p.addLine(to: CGPoint(x: 95, y: 50))
        p.addQuadCurve(to: CGPoint(x: 109, y: 64), control: CGPoint(x: 95, y: 64))
        p.addLine(to: CGPoint(x: 171, y: 64))
        p.addQuadCurve(to: CGPoint(x: 185, y: 50), control: CGPoint(x: 185, y: 64))
        p.addLine(to: CGPoint(x: 185, y: 40))
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared logo body

/// Renders the logo at the native 280×220 scale; callers wrap this and scale it
/// to the size they need. `eyes` supplies the (possibly animated) eye state.
private struct MackyLogoCanvas: View {
    var color: Color
    /// Vertical scale of each eye (1 = open, →0 = closed) and shared horizontal
    /// gaze offset, in source-space units.
    var leftEyeScaleY: CGFloat
    var rightEyeScaleY: CGFloat
    var gazeOffsetX: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            MackyBodyShape()
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: MackyGeometry.bodyStrokeWidth,
                        lineJoin: .round
                    )
                )

            MackyNotchTabShape()
                .fill(color)

            eye(centerX: MackyGeometry.leftEyeCenterX, scaleY: leftEyeScaleY)
            eye(centerX: MackyGeometry.rightEyeCenterX, scaleY: rightEyeScaleY)
        }
        .frame(width: MackyGeometry.artboard.width, height: MackyGeometry.artboard.height)
    }

    @ViewBuilder
    private func eye(centerX: CGFloat, scaleY: CGFloat) -> some View {
        let h = max(MackyGeometry.eyeSize * scaleY, 0.5)
        RoundedRectangle(cornerRadius: min(MackyGeometry.eyeCornerRadius, h / 2), style: .continuous)
            .fill(color)
            .frame(width: MackyGeometry.eyeSize, height: h)
            .position(x: centerX + gazeOffsetX, y: MackyGeometry.eyeCenterY)
    }
}

// MARK: - Static logo

/// The standard, at-rest Macky logo. `size` is the rendered width; height keeps
/// the native 280:220 aspect ratio. `color` is the ink color (default white, for
/// the dark surfaces this app uses).
struct MackyLogoView: View {
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        let scale = size / MackyGeometry.artboard.width
        MackyLogoCanvas(
            color: color,
            leftEyeScaleY: 1,
            rightEyeScaleY: 1,
            gazeOffsetX: 0
        )
        .scaleEffect(scale)
        .frame(
            width: size,
            height: MackyGeometry.artboard.height * scale
        )
    }
}

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

// MARK: - Animated logo (notch only)

/// The living Macky logo: eyes blink, look around, wink, and squint on a gently
/// randomized loop. Ported from the brand reference animation. Intended to live
/// in the notch as the persistent identity.
struct MackyAnimatedLogoView: View {
    var size: CGFloat
    var color: Color = .white

    @State private var leftEyeScaleY: CGFloat = 1
    @State private var rightEyeScaleY: CGFloat = 1
    @State private var gazeOffsetX: CGFloat = 0
    @State private var driver: Task<Void, Never>? = nil

    var body: some View {
        let scale = size / MackyGeometry.artboard.width
        MackyLogoCanvas(
            color: color,
            leftEyeScaleY: leftEyeScaleY,
            rightEyeScaleY: rightEyeScaleY,
            gazeOffsetX: gazeOffsetX
        )
        .scaleEffect(scale)
        .frame(
            width: size,
            height: MackyGeometry.artboard.height * scale
        )
        .onAppear { startDriver() }
        .onDisappear {
            driver?.cancel()
            driver = nil
        }
    }

    private func startDriver() {
        guard driver == nil else { return }
        driver = Task { await runLoop() }
    }

    // MARK: Animation loop (mirrors the reference `acts` sequence)

    @MainActor
    private func runLoop() async {
        try? await Task.sleep(for: .milliseconds(1200))
        let acts: [() async -> Void] = [
            blink,
            { await look(13) },
            blink,
            { await look(-11) },
            wink,
            blink,
            squint,
            { await look(9) },
            blink,
            wink,
            { await look(-7) },
            blink,
        ]
        var index = 0
        while !Task.isCancelled {
            await acts[index % acts.count]()
            index += 1
            let gap = Int(800 + Double.random(in: 0...1600))
            try? await Task.sleep(for: .milliseconds(gap))
        }
    }

    @MainActor
    private func blink() async {
        withAnimation(.easeInOut(duration: 0.09)) {
            leftEyeScaleY = 0.06
            rightEyeScaleY = 0.06
        }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.easeInOut(duration: 0.11)) {
            leftEyeScaleY = 1
            rightEyeScaleY = 1
        }
        try? await Task.sleep(for: .milliseconds(110))
    }

    @MainActor
    private func look(_ dx: CGFloat) async {
        withAnimation(.easeInOut(duration: 0.2)) { gazeOffsetX = dx }
        try? await Task.sleep(for: .milliseconds(950)) // hold ~0.75s after the 0.2s move
        withAnimation(.easeInOut(duration: 0.2)) { gazeOffsetX = 0 }
        try? await Task.sleep(for: .milliseconds(200))
    }

    @MainActor
    private func wink() async {
        withAnimation(.easeInOut(duration: 0.16)) { leftEyeScaleY = 0.05 }
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.easeInOut(duration: 0.16)) { leftEyeScaleY = 1 }
        try? await Task.sleep(for: .milliseconds(160))
    }

    @MainActor
    private func squint() async {
        withAnimation(.easeInOut(duration: 0.16)) {
            leftEyeScaleY = 0.28
            rightEyeScaleY = 0.28
        }
        try? await Task.sleep(for: .milliseconds(710)) // hold ~0.55s after the move
        withAnimation(.easeInOut(duration: 0.18)) {
            leftEyeScaleY = 1
            rightEyeScaleY = 1
        }
        try? await Task.sleep(for: .milliseconds(180))
    }
}

#if DEBUG
#Preview("Static") {
    MackyLogoView(size: 120, color: .black)
        .padding(40)
        .background(Color(white: 0.98))
}

#Preview("Animated") {
    MackyAnimatedLogoView(size: 120)
        .padding(40)
        .background(Color.black)
}
#endif
