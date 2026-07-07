//
//  VisualSceneBuilder.swift
//  leanring-buddy
//
//  Builds a conservative main-display target map for visual guidance.
//

import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum VisualSceneBuilder {
    private static let coordinateSpace = "top_left_logical_screen_points_main_display"
    private static let maxAccessibilityTargets = 50
    private static let maxTraversalDepth = 4

    static func buildMainDisplayScene() -> VisualScene? {
        guard let screen = NSScreen.main else { return nil }
        let targets = accessibilityTargets(on: screen, remaining: maxAccessibilityTargets)

        return VisualScene(
            screenWidth: Double(screen.frame.width),
            screenHeight: Double(screen.frame.height),
            coordinateSpace: coordinateSpace,
            targets: targets
        )
    }

    private static func accessibilityTargets(on screen: NSScreen, remaining: Int) -> [VisualTarget] {
        guard AXIsProcessTrusted(), remaining > 0 else { return [] }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return [] }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var targets: [VisualTarget] = []
        var markerIndex = 1
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for (windowIndex, window) in windows.prefix(3).enumerated() {
                guard targets.count < remaining else { break }
                if let target = target(from: window, id: "app_window_\(windowIndex + 1)", marker: "\(markerIndex)", kind: .appWindow, fallbackRole: "window", screen: screen, confidence: 0.86) {
                    targets.append(target)
                    markerIndex += 1
                }
                collectTargets(from: window, prefix: "ax_\(windowIndex + 1)", depth: 0, screen: screen, into: &targets, markerIndex: &markerIndex, limit: remaining)
            }
        }
        return targets
    }

    private static func collectTargets(
        from element: AXUIElement,
        prefix: String,
        depth: Int,
        screen: NSScreen,
        into targets: inout [VisualTarget],
        markerIndex: inout Int,
        limit: Int
    ) {
        guard depth <= maxTraversalDepth, targets.count < limit else { return }

        if let target = target(
            from: element,
            id: "\(prefix)_\(targets.count + 1)",
            marker: "\(markerIndex)",
            kind: .accessibilityElement,
            fallbackRole: "control",
            screen: screen,
            confidence: 0.72
        ), shouldKeepAccessibilityTarget(target) {
            targets.append(target)
            markerIndex += 1
        }

        guard targets.count < limit else { return }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }

        for child in children.prefix(30) {
            guard targets.count < limit else { break }
            collectTargets(from: child, prefix: prefix, depth: depth + 1, screen: screen, into: &targets, markerIndex: &markerIndex, limit: limit)
        }
    }

    private static func target(
        from element: AXUIElement,
        id: String,
        marker: String?,
        kind: VisualTargetKind,
        fallbackRole: String,
        screen: NSScreen,
        confidence: Double
    ) -> VisualTarget? {
        guard let box = topLeftBox(for: element, on: screen) else { return nil }
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? fallbackRole
        let label = [
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXValueAttribute, from: element)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }

        return VisualTarget(
            id: id,
            kind: kind,
            role: role,
            label: label,
            marker: marker,
            box: box,
            confidence: confidence
        )
    }

    private static func shouldKeepAccessibilityTarget(_ target: VisualTarget) -> Bool {
        guard target.box.width >= 8, target.box.height >= 8 else { return false }
        let usefulRoles = [
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXPopUpButtonRole as String,
            kAXMenuButtonRole as String,
            kAXMenuItemRole as String,
            kAXTabGroupRole as String,
            "AXLink",
            kAXWindowRole as String
        ]
        if usefulRoles.contains(target.role) { return true }
        return target.label?.isEmpty == false && target.box.width >= 24 && target.box.height >= 16
    }

    private static func topLeftBox(for element: AXUIElement, on screen: NSScreen) -> VisualTargetBox? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success else { return nil }
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }
        guard let positionAXValue = positionValue as! AXValue?,
              let sizeAXValue = sizeValue as! AXValue? else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position) else { return nil }
        guard AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }

        let frame = screen.frame
        let screenRect = CGRect(origin: .zero, size: frame.size)
        let candidateRects = [
            CGRect(origin: CGPoint(x: position.x - frame.minX, y: position.y - frame.minY), size: size),
            CGRect(origin: CGPoint(x: position.x - frame.minX, y: position.y), size: size)
        ]

        let intersections = candidateRects.map { $0.intersection(screenRect) }
        var intersection: CGRect?
        for candidate in intersections where !candidate.isNull && candidate.width > 0 && candidate.height > 0 {
            if let current = intersection {
                let currentArea = current.width * current.height
                let candidateArea = candidate.width * candidate.height
                if candidateArea > currentArea {
                    intersection = candidate
                }
            } else {
                intersection = candidate
            }
        }

        guard let intersection else { return nil }

        let topLeftBox = VisualTargetBox(
            x: Double(intersection.minX),
            y: Double(intersection.minY),
            width: Double(intersection.width),
            height: Double(intersection.height)
        )
        return topLeftBox.clamped(to: frame.size)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
