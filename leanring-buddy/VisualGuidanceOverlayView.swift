//
//  VisualGuidanceOverlayView.swift
//  leanring-buddy
//
//  SwiftUI renderer for Macky's full-screen teaching overlay.
//

import SwiftUI

struct VisualGuidanceOverlayView: View {
    let step: VisualGuidanceStep
    let sourceSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(step.canvas.enumerated()), id: \.offset) { _, command in
                    commandView(command, in: geometry.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.18), value: step.canvas.count)
        }
        .allowsHitTesting(false)
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
        case .arrow:
            if let start = point(x: command.x, y: command.y, in: targetSize),
               let end = point(x: command.toX, y: command.toY, in: targetSize) {
                ArrowShape(start: start, end: end)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: Color.blue.opacity(0.45), radius: 10)
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
