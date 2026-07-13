//
//  CursorControlIntegration.swift
//  leanring-buddy
//
//  Standalone local cursor automation. Visual guidance may use this engine to point,
//  but clicking, dragging, and scrolling are independent realtime tools.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CursorControlAction: String {
    case move
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case middleClick = "middle_click"
    case drag
    case scroll
}

enum CursorControlButton: String {
    case left
    case right
    case middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var draggedEventType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }
}

struct CursorControlRequest {
    let action: CursorControlAction
    let x: Double?
    let y: Double?
    let toX: Double?
    let toY: Double?
    let duration: TimeInterval
    let button: CursorControlButton
    let scrollDeltaX: Int32
    let scrollDeltaY: Int32
    let expectedApplicationBundleIdentifier: String?
}

@MainActor
enum CursorControlIntegration {
    static func perform(
        _ request: CursorControlRequest,
        coordinateSpace: VisualGuidanceCoordinateSpace?
    ) async throws -> String {
        guard AXIsProcessTrusted() else {
            throw CursorControlError.accessibilityPermissionRequired
        }
        try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)

        switch request.action {
        case .move:
            let target = try requiredPoint(x: request.x, y: request.y, coordinateSpace: coordinateSpace)
            try await moveSmoothly(
                to: target,
                duration: request.duration,
                expectedApplicationBundleIdentifier: request.expectedApplicationBundleIdentifier
            )
        case .click:
            try await moveIfRequested(request, coordinateSpace: coordinateSpace)
            try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)
            try postClick(button: request.button, clickCount: 1)
        case .doubleClick:
            try await moveIfRequested(request, coordinateSpace: coordinateSpace)
            try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)
            try postClick(button: request.button, clickCount: 2)
        case .rightClick:
            try await moveIfRequested(request, coordinateSpace: coordinateSpace)
            try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)
            try postClick(button: .right, clickCount: 1)
        case .middleClick:
            try await moveIfRequested(request, coordinateSpace: coordinateSpace)
            try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)
            try postClick(button: .middle, clickCount: 1)
        case .drag:
            let start = try optionalPoint(x: request.x, y: request.y, coordinateSpace: coordinateSpace)
                ?? NSEvent.mouseLocation
            let end = try requiredPoint(x: request.toX, y: request.toY, coordinateSpace: coordinateSpace)
            try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)
            try await drag(
                from: start,
                to: end,
                duration: request.duration,
                button: request.button,
                expectedApplicationBundleIdentifier: request.expectedApplicationBundleIdentifier
            )
        case .scroll:
            try await moveIfRequested(request, coordinateSpace: coordinateSpace)
            try verifyExpectedApplication(request.expectedApplicationBundleIdentifier)
            try postScroll(deltaX: request.scrollDeltaX, deltaY: request.scrollDeltaY)
        }

        return "{\"status\":\"cursor_action_completed\",\"action\":\"\(request.action.rawValue)\"}"
    }

    /// Visual guidance uses the standalone cursor engine for pointing only.
    static func move(
        to command: CursorCommand,
        coordinateSpace: VisualGuidanceCoordinateSpace?,
        expectedApplicationBundleIdentifier: String?
    ) async throws -> String {
        try await perform(
            CursorControlRequest(
                action: .move,
                x: command.x,
                y: command.y,
                toX: nil,
                toY: nil,
                duration: command.duration,
                button: .left,
                scrollDeltaX: 0,
                scrollDeltaY: 0,
                expectedApplicationBundleIdentifier: expectedApplicationBundleIdentifier
            ),
            coordinateSpace: coordinateSpace
        )
    }

    static func appKitPoint(
        x: Double,
        y: Double,
        coordinateSpace: VisualGuidanceCoordinateSpace?
    ) throws -> CGPoint {
        let frame: CGRect
        if let displayFrame = coordinateSpace?.displayFrame,
           let displayID = displayFrame.displayID {
            guard let screen = NSScreen.screens.first(where: { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) else {
                throw CursorControlError.noScreen
            }
            frame = screen.frame
        } else if let displayFrame = coordinateSpace?.displayFrame?.cgRect {
            frame = displayFrame
        } else if let screen = NSScreen.main {
            frame = screen.frame
        } else {
            throw CursorControlError.noScreen
        }
        guard frame.width > 1, frame.height > 1 else { throw CursorControlError.noScreen }

        let sourceSize = coordinateSpace?.cgSize ?? frame.size
        guard x.isFinite, y.isFinite,
              x >= 0, y >= 0,
              x <= Double(sourceSize.width), y <= Double(sourceSize.height) else {
            throw CursorControlError.coordinateOutOfBounds
        }

        let normalizedX = CGFloat(x) / max(1, sourceSize.width)
        let normalizedY = CGFloat(y) / max(1, sourceSize.height)
        let mappedPoint = CGPoint(
            x: frame.minX + normalizedX * frame.width,
            y: frame.maxY - normalizedY * frame.height
        )
        // Keep edge coordinates inside the selected display. A point exactly on maxX/maxY
        // can belong to an adjacent display even though it is a valid drawing coordinate.
        return CGPoint(
            x: min(max(mappedPoint.x, frame.minX + 0.5), frame.maxX - 0.5),
            y: min(max(mappedPoint.y, frame.minY + 0.5), frame.maxY - 0.5)
        )
    }

    private static func requiredPoint(
        x: Double?,
        y: Double?,
        coordinateSpace: VisualGuidanceCoordinateSpace?
    ) throws -> CGPoint {
        guard let x, let y else { throw CursorControlError.missingCoordinates }
        return try appKitPoint(x: x, y: y, coordinateSpace: coordinateSpace)
    }

    private static func optionalPoint(
        x: Double?,
        y: Double?,
        coordinateSpace: VisualGuidanceCoordinateSpace?
    ) throws -> CGPoint? {
        if x == nil, y == nil { return nil }
        guard let x, let y else { throw CursorControlError.missingCoordinates }
        return try appKitPoint(x: x, y: y, coordinateSpace: coordinateSpace)
    }

    private static func moveIfRequested(
        _ request: CursorControlRequest,
        coordinateSpace: VisualGuidanceCoordinateSpace?
    ) async throws {
        guard let target = try optionalPoint(x: request.x, y: request.y, coordinateSpace: coordinateSpace) else {
            return
        }
        try await moveSmoothly(
            to: target,
            duration: request.duration,
            expectedApplicationBundleIdentifier: request.expectedApplicationBundleIdentifier
        )
    }

    private static func moveSmoothly(
        to target: CGPoint,
        duration: TimeInterval,
        expectedApplicationBundleIdentifier: String?
    ) async throws {
        let start = NSEvent.mouseLocation
        try await emitMovement(
            from: start,
            to: target,
            duration: duration,
            eventType: .mouseMoved,
            button: .left,
            expectedApplicationBundleIdentifier: expectedApplicationBundleIdentifier
        )
    }

    private static func drag(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        button: CursorControlButton,
        expectedApplicationBundleIdentifier: String?
    ) async throws {
        try await moveSmoothly(
            to: start,
            duration: min(duration * 0.25, 0.35),
            expectedApplicationBundleIdentifier: expectedApplicationBundleIdentifier
        )
        try verifyExpectedApplication(expectedApplicationBundleIdentifier)
        try postMouseEvent(type: button.downEventType, button: button.cgButton, at: start)

        do {
            try await emitMovement(
                from: start,
                to: end,
                duration: duration,
                eventType: button.draggedEventType,
                button: button.cgButton,
                expectedApplicationBundleIdentifier: expectedApplicationBundleIdentifier
            )
            try verifyExpectedApplication(expectedApplicationBundleIdentifier)
            try postMouseEvent(type: button.upEventType, button: button.cgButton, at: end)
        } catch {
            // Always release the button when cancellation or event creation interrupts a drag.
            try? postMouseEvent(type: button.upEventType, button: button.cgButton, at: NSEvent.mouseLocation)
            throw error
        }
    }

    private static func emitMovement(
        from start: CGPoint,
        to target: CGPoint,
        duration: TimeInterval,
        eventType: CGEventType,
        button: CGMouseButton,
        expectedApplicationBundleIdentifier: String?
    ) async throws {
        let safeDuration = min(max(duration, 0.05), 3.0)
        let steps = max(1, min(120, Int(safeDuration / 0.012)))
        let sleepNanoseconds = UInt64(safeDuration / Double(steps) * 1_000_000_000)

        for index in 1...steps {
            try Task.checkCancellation()
            try verifyExpectedApplication(expectedApplicationBundleIdentifier)
            let progress = CGFloat(index) / CGFloat(steps)
            let easedProgress = progress * progress * (3 - 2 * progress)
            let appKitPoint = CGPoint(
                x: start.x + (target.x - start.x) * easedProgress,
                y: start.y + (target.y - start.y) * easedProgress
            )
            try postMouseEvent(type: eventType, button: button, at: appKitPoint)
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }
    }

    private static func postClick(button: CursorControlButton, clickCount: Int) throws {
        let point = NSEvent.mouseLocation
        for clickIndex in 1...clickCount {
            let eventClickState = clickCount == 1 ? 1 : clickIndex
            try postMouseEvent(
                type: button.downEventType,
                button: button.cgButton,
                at: point,
                clickState: eventClickState
            )
            try postMouseEvent(
                type: button.upEventType,
                button: button.cgButton,
                at: point,
                clickState: eventClickState
            )
        }
    }

    private static func postMouseEvent(
        type: CGEventType,
        button: CGMouseButton,
        at appKitPoint: CGPoint,
        clickState: Int = 1
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: quartzPoint(fromAppKitPoint: appKitPoint),
            mouseButton: button
        ) else {
            throw CursorControlError.eventCreationFailed
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    private static func postScroll(deltaX: Int32, deltaY: Int32) throws {
        guard deltaX != 0 || deltaY != 0 else { throw CursorControlError.missingScrollDelta }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw CursorControlError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    private static func verifyExpectedApplication(_ expectedBundleIdentifier: String?) throws {
        guard let expectedBundleIdentifier else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleIdentifier else {
            throw CursorControlError.applicationChanged
        }
    }

    // AppKit uses a global bottom-left origin. CGEvent uses the primary display's
    // global top-left origin. The display-local image scaling happens before this flip.
    private static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        let primaryDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: point.x, y: primaryDisplayBounds.height - point.y)
    }
}

enum CursorControlError: LocalizedError {
    case accessibilityPermissionRequired
    case noScreen
    case missingCoordinates
    case coordinateOutOfBounds
    case applicationChanged
    case displayIDRequired
    case missingScrollDelta
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "cursor control needs Accessibility permission. Tell the user to enable Macky in System Settings, Privacy & Security, Accessibility, then try again."
        case .noScreen:
            return "no screen is available for cursor control"
        case .missingCoordinates:
            return "cursor action is missing required coordinates"
        case .coordinateOutOfBounds:
            return "cursor coordinates are outside the selected screen capture"
        case .applicationChanged:
            return "the frontmost application changed after the cursor coordinates were captured"
        case .displayIDRequired:
            return "cursor coordinates are ambiguous because multiple screens were captured; provide display_id"
        case .missingScrollDelta:
            return "scroll action requires a horizontal or vertical delta"
        case .eventCreationFailed:
            return "macOS could not create the cursor event"
        }
    }
}
