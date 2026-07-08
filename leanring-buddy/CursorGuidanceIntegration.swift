//
//  CursorGuidanceIntegration.swift
//  leanring-buddy
//
//  Local cursor guidance for visual teaching. Macky uses this only for pointing
//  during an explicit help flow; no clicking, dragging, or typing lives here.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
enum CursorGuidanceIntegration {
    static func move(to command: CursorCommand, coordinateSpace: VisualGuidanceCoordinateSpace?) async throws -> String {
        let target = try appKitPoint(x: command.x, y: command.y, coordinateSpace: coordinateSpace)
        try await moveSmoothly(to: target, duration: command.duration)
        return "{\"status\": \"cursor moved\"}"
    }

    static func appKitPoint(x: Double, y: Double, coordinateSpace: VisualGuidanceCoordinateSpace?) throws -> CGPoint {
        let frame: CGRect
        if let displayFrame = coordinateSpace?.displayFrame?.cgRect {
            frame = displayFrame
        } else if let screen = NSScreen.main {
            frame = screen.frame
        } else {
            throw CursorGuidanceError.noMainScreen
        }
        let source = coordinateSpace?.cgSize ?? frame.size
        let normalizedX = CGFloat(x) / max(1, source.width)
        let normalizedY = CGFloat(y) / max(1, source.height)
        let clampedX = min(max(normalizedX, 0), 1)
        let clampedY = min(max(normalizedY, 0), 1)
        return CGPoint(
            x: frame.minX + clampedX * frame.width,
            y: frame.maxY - clampedY * frame.height
        )
    }

    private static func moveSmoothly(to target: CGPoint, duration: TimeInterval) async throws {
        let start = NSEvent.mouseLocation
        let steps = max(1, min(60, Int(duration / 0.012)))
        for index in 1...steps {
            let progress = CGFloat(index) / CGFloat(steps)
            let eased = easeInOut(progress)
            let point = CGPoint(
                x: start.x + (target.x - start.x) * eased,
                y: start.y + (target.y - start.y) * eased
            )
            CGWarpMouseCursorPosition(quartzPoint(fromAppKitPoint: point))
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
        }
        CGWarpMouseCursorPosition(quartzPoint(fromAppKitPoint: target))
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }

    // `NSEvent.mouseLocation` and AppKit screen frames use a bottom-left origin; CGEvent /
    // CGWarpMouseCursorPosition expect a global top-left origin anchored to the primary display.
    // This performs the single, correct flip. All AppKit points fed to CGEvent must go through
    // here — do NOT add a second flip anywhere upstream, and do NOT multiply by a display scale
    // factor (the screenshot is captured in logical points, so coordinates are already in logical space).
    private static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: point.x, y: mainBounds.height - point.y)
    }
}

enum CursorGuidanceError: LocalizedError {
    case noMainScreen

    var errorDescription: String? {
        switch self {
        case .noMainScreen:
            return "no main screen available"
        }
    }
}
