//
//  VisualSceneBuilder.swift
//  leanring-buddy
//
//  Builds a conservative Accessibility target map of the captured display for
//  visual guidance.
//

import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum VisualSceneBuilder {
    private static let coordinateSpace = "top_left_logical_points_captured_display"
    private static let maxAccessibilityTargets = 80
    private static let maxTraversalDepth = 10
    private static let maxChildrenPerElement = 50
    // Every AXUIElementCopyAttributeValue call is a synchronous IPC round trip on the
    // main thread, so the traversal is bounded by visited elements, not just kept targets.
    private static let maxVisitedElements = 1_500

    static func buildScene(for screen: NSScreen) -> VisualScene? {
        let targets = accessibilityTargets(on: screen, limit: maxAccessibilityTargets)

        return VisualScene(
            screenWidth: Double(screen.frame.width),
            screenHeight: Double(screen.frame.height),
            coordinateSpace: coordinateSpace,
            targets: targets
        )
    }

    private static func accessibilityTargets(on screen: NSScreen, limit: Int) -> [VisualTarget] {
        guard AXIsProcessTrusted(), limit > 0 else { return [] }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return [] }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowTargets: [VisualTarget] = []
        var priorityTargets: [VisualTarget] = []
        var labeledFallbackTargets: [VisualTarget] = []
        var visitedElements = 0

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for (windowIndex, window) in windows.prefix(3).enumerated() {
                if let target = target(from: window, id: "app_window_\(windowIndex + 1)", marker: nil, kind: .appWindow, fallbackRole: "window", screen: screen, confidence: 0.86) {
                    windowTargets.append(target)
                }
                // Breadth-first so shallow controls (toolbars, tab strips) are found before
                // the visit budget is spent deep inside one branch, and collect-then-filter
                // so real controls are not crowded out by containers encountered first.
                var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
                var queueIndex = 0
                while queueIndex < queue.count, visitedElements < maxVisitedElements {
                    let (element, depth) = queue[queueIndex]
                    queueIndex += 1
                    visitedElements += 1

                    if depth > 0, let target = target(
                        from: element,
                        id: "ax_\(windowIndex + 1)_\(visitedElements)",
                        marker: nil,
                        kind: .accessibilityElement,
                        fallbackRole: "control",
                        screen: screen,
                        confidence: 0.72
                    ) {
                        if isPriorityTarget(target) {
                            priorityTargets.append(target)
                        } else if isLabeledFallback(target) {
                            labeledFallbackTargets.append(target)
                        }
                    }

                    guard depth < maxTraversalDepth else { continue }
                    var childrenValue: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                          let children = childrenValue as? [AXUIElement] else { continue }
                    for child in children.prefix(maxChildrenPerElement) {
                        queue.append((child, depth + 1))
                    }
                }
            }
        }

        let selected = Array((windowTargets + priorityTargets + labeledFallbackTargets).prefix(limit))
        // Markers are assigned after selection so they stay dense (1, 2, 3, …) even
        // though the traversal skipped elements.
        return selected.enumerated().map { index, target in
            VisualTarget(
                id: target.id,
                kind: target.kind,
                role: target.role,
                label: target.label,
                marker: "\(index + 1)",
                box: target.box,
                confidence: target.confidence
            )
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

    private static let priorityRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXMenuItemRole as String,
        kAXTabGroupRole as String,
        "AXLink"
    ]

    private static func isPriorityTarget(_ target: VisualTarget) -> Bool {
        guard target.box.width >= 8, target.box.height >= 8 else { return false }
        return priorityRoles.contains(target.role)
    }

    private static func isLabeledFallback(_ target: VisualTarget) -> Bool {
        guard target.box.width >= 8, target.box.height >= 8 else { return false }
        return target.label?.isEmpty == false && target.box.width >= 24 && target.box.height >= 16
    }

    private static func topLeftBox(for element: AXUIElement, on screen: NSScreen) -> VisualTargetBox? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success else { return nil }
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position) else { return nil }
        guard AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        let screenRect = CGRect(origin: .zero, size: screen.frame.size)
        let localTopLeftRect = CGRect(
            x: position.x - quartzDisplayFrame.minX,
            y: position.y - quartzDisplayFrame.minY,
            width: size.width,
            height: size.height
        )
        let intersection = localTopLeftRect.intersection(screenRect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }

        let topLeftBox = VisualTargetBox(
            x: Double(intersection.minX),
            y: Double(intersection.minY),
            width: Double(intersection.width),
            height: Double(intersection.height)
        )
        return topLeftBox.clamped(to: screen.frame.size)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
