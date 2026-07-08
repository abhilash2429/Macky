//
//  VisualGuidanceOverlayView.swift
//  leanring-buddy
//
//  SwiftUI renderer for Macky's full-screen teaching overlay.
//

import AppKit
import SwiftUI

struct VisualGuidanceOverlayView: View {
    let step: VisualGuidanceStep
    let sourceSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(step.canvas.enumerated()), id: \.offset) { _, command in
                    AnimatedCanvasCommandView(command: command, targetSize: geometry.size, sourceSize: sourceSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                print("🧪 VisualGuidanceRenderDiagnostics targetSize=\(geometry.size.debugDescription) sourceSize=\(sourceSize.debugDescription) scaleX=\(geometry.size.width / max(1, sourceSize.width)) scaleY=\(geometry.size.height / max(1, sourceSize.height)) commands=\(step.canvas.count)")
            }
            .animation(.easeInOut(duration: 0.18), value: step.canvas.count)
        }
        .allowsHitTesting(false)
    }
}

private struct AnimatedCanvasCommandView: View {
    let command: CanvasCommand
    let targetSize: CGSize
    let sourceSize: CGSize

    @State private var visible = false
    @State private var progress: CGFloat = 0
    @State private var pulse = false
    @State private var dashPhase: CGFloat = 0

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var animationType: CanvasAnimationType {
        if command.animation?.type == .none { return .none }
        return reduceMotion ? .fadeIn : (command.animation?.type ?? .fadeIn)
    }

    private var duration: Double {
        reduceMotion ? 0.18 : (command.animation?.duration ?? 0.45)
    }

    private var delay: Double {
        reduceMotion ? 0 : (command.animation?.delay ?? 0)
    }

    private var repetitions: Int {
        reduceMotion ? 1 : (command.animation?.repetitions ?? 1)
    }

    var body: some View {
        commandView(command, in: targetSize)
            .opacity(opacity)
            .scaleEffect(scale)
            .onAppear(perform: startAnimation)
    }

    @ViewBuilder
    private func commandView(_ command: CanvasCommand, in targetSize: CGSize) -> some View {
        switch command.type {
        case .highlight:
            if let rect = rect(for: command, in: targetSize) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.blue.opacity(0.95), lineWidth: 3)
                    )
                    .shadow(color: Color.blue.opacity(0.55), radius: 16)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        case .circle:
            if let rect = rect(for: command, in: targetSize) {
                Ellipse()
                    .fill(Color.blue.opacity(0.14))
                    .overlay(Ellipse().stroke(Color.blue.opacity(0.95), lineWidth: 3))
                    .shadow(color: Color.blue.opacity(0.45), radius: 14)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        case .ring:
            if let rect = rect(for: command, in: targetSize) {
                Ellipse()
                    .stroke(Color.blue.opacity(0.95), lineWidth: 4)
                    .shadow(color: Color.blue.opacity(0.5), radius: 12)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        case .spotlight:
            if let rect = rect(for: command, in: targetSize) {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.34)
                        .frame(width: targetSize.width, height: targetSize.height)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.blue.opacity(0.95), lineWidth: 3)
                        )
                        .shadow(color: Color.blue.opacity(0.65), radius: 22)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        case .arrow:
            if let start = point(x: command.x, y: command.y, in: targetSize),
               let end = point(x: command.toX, y: command.toY, in: targetSize) {
                arrowShape(start: start, end: end)
                    .shadow(color: Color.blue.opacity(0.45), radius: 10)
            }
        case .line:
            if let start = point(x: command.x, y: command.y, in: targetSize),
               let end = point(x: command.toX, y: command.toY, in: targetSize) {
                lineShape(start: start, end: end)
                    .shadow(color: Color.blue.opacity(0.35), radius: 8)
            }
        case .label:
            if let label = command.text,
               let anchor = point(x: command.x, y: command.y, in: targetSize) {
                Text(label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.76))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .position(anchor)
            }
        case .polygon:
            if let points = command.points, points.count >= 3 {
                PolygonShape(points: points.map { point(x: $0.x, y: $0.y, in: targetSize) })
                    .fill(Color.blue.opacity(0.12))
                    .overlay(
                        PolygonShape(points: points.map { point(x: $0.x, y: $0.y, in: targetSize) })
                            .stroke(Color.blue.opacity(0.95), lineWidth: 3)
                    )
                    .shadow(color: Color.blue.opacity(0.4), radius: 12)
            }
        case .brace:
            if let rect = rect(for: command, in: targetSize) {
                BraceShape(rect: rect)
                    .stroke(Color.blue.opacity(0.95), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: Color.blue.opacity(0.35), radius: 10)
            }
        }
    }

    private func rect(for command: CanvasCommand, in targetSize: CGSize) -> CGRect? {
        guard let x = command.x, let y = command.y, let width = command.width, let height = command.height else { return nil }
        let origin = point(x: x, y: y, in: targetSize)
        let size = CGSize(width: CGFloat(width) * scaleX(targetSize), height: CGFloat(height) * scaleY(targetSize))
        return CGRect(origin: origin, size: size)
    }

    private func point(x: Double?, y: Double?, in targetSize: CGSize) -> CGPoint? {
        guard let x, let y else { return nil }
        return point(x: x, y: y, in: targetSize)
    }

    // SwiftUI's coordinate space here is already top-left origin (`.position` measures y
    // downward from the top), so no Y flip is needed. Since the screenshot is now captured at
    // the display's logical point dimensions, `sourceSize` equals the fullscreen overlay's
    // `targetSize`, so scaleX/scaleY are 1.0 and this is effectively a direct passthrough:
    // overlayX == screenshotX, overlayY == screenshotY.
    private func point(x: Double, y: Double, in targetSize: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * scaleX(targetSize), y: CGFloat(y) * scaleY(targetSize))
    }

    private func scaleX(_ targetSize: CGSize) -> CGFloat {
        targetSize.width / max(1, sourceSize.width)
    }

    private func scaleY(_ targetSize: CGSize) -> CGFloat {
        targetSize.height / max(1, sourceSize.height)
    }

    @ViewBuilder
    private func arrowShape(start: CGPoint, end: CGPoint) -> some View {
        strokedPath(ArrowShape(start: start, end: end))
    }

    @ViewBuilder
    private func lineShape(start: CGPoint, end: CGPoint) -> some View {
        strokedPath(LineShape(start: start, end: end))
    }

    @ViewBuilder
    private func strokedPath<S: Shape>(_ shape: S) -> some View {
        let dash: [CGFloat] = animationType == .dashFlow ? [10, 8] : []
        let style = StrokeStyle(
            lineWidth: 4,
            lineCap: .round,
            lineJoin: .round,
            dash: dash,
            dashPhase: dashPhase
        )
        if animationType == .draw || animationType == .travel {
            shape
                .trim(from: 0, to: progress)
                .stroke(Color.blue, style: style)
        } else {
            shape.stroke(Color.blue, style: style)
        }
    }

    private var opacity: Double {
        switch animationType {
        case .none:
            return 1
        default:
            return visible ? 1 : 0
        }
    }

    private var scale: CGFloat {
        switch animationType {
        case .scaleIn:
            return visible ? 1 : 0.88
        case .pulse:
            return pulse ? 1.04 : 1
        default:
            return 1
        }
    }

    private func startAnimation() {
        guard animationType != .none else {
            visible = true
            progress = 1
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let base = swiftUIAnimation()
            switch animationType {
            case .draw, .travel:
                visible = true
                withAnimation(base) { progress = 1 }
            case .pulse:
                visible = true
                progress = 1
                guard repetitions > 0 else { return }
                withAnimation(base.repeatCount(repetitions, autoreverses: true)) { pulse = true }
            case .dashFlow:
                visible = true
                progress = 1
                guard repetitions > 0 else { return }
                withAnimation(.linear(duration: duration).repeatCount(repetitions, autoreverses: false)) { dashPhase = -72 }
            case .fadeIn, .scaleIn:
                progress = 1
                withAnimation(base) { visible = true }
            case .none:
                visible = true
                progress = 1
            }
        }
    }

    private func swiftUIAnimation() -> Animation {
        switch command.animation?.easing ?? .easeInOut {
        case .linear:
            return .linear(duration: duration)
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        }
    }
}

private struct LineShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}

private struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 18
        let headAngle: CGFloat = .pi / 7
        let pointA = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let pointB = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        path.move(to: end)
        path.addLine(to: pointA)
        path.move(to: end)
        path.addLine(to: pointB)
        return path
    }
}

private struct BraceShape: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        var path = Path()
        let x = rect.minX
        let top = rect.minY
        let bottom = rect.maxY
        let midY = rect.midY
        let width = min(max(rect.width * 0.12, 14), 34)
        let curve = min(max(rect.height * 0.12, 10), 28)

        path.move(to: CGPoint(x: x + width, y: top))
        path.addCurve(
            to: CGPoint(x: x, y: top + curve),
            control1: CGPoint(x: x + width * 0.35, y: top),
            control2: CGPoint(x: x, y: top + curve * 0.35)
        )
        path.addLine(to: CGPoint(x: x, y: midY - curve))
        path.addCurve(
            to: CGPoint(x: x + width, y: midY),
            control1: CGPoint(x: x, y: midY - curve * 0.35),
            control2: CGPoint(x: x + width * 0.35, y: midY)
        )
        path.addCurve(
            to: CGPoint(x: x, y: midY + curve),
            control1: CGPoint(x: x + width * 0.35, y: midY),
            control2: CGPoint(x: x, y: midY + curve * 0.35)
        )
        path.addLine(to: CGPoint(x: x, y: bottom - curve))
        path.addCurve(
            to: CGPoint(x: x + width, y: bottom),
            control1: CGPoint(x: x, y: bottom - curve * 0.35),
            control2: CGPoint(x: x + width * 0.35, y: bottom)
        )
        return path
    }
}

private struct PolygonShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
