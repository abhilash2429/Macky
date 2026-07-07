//
//  VisualSceneModels.swift
//  leanring-buddy
//
//  Main-display visual targets that GPT-Realtime can reference by ID.
//  Coordinates are top-left logical screen points, matching the screenshot and overlay.
//

import CoreGraphics
import Foundation

struct VisualScene: Codable {
    let screenWidth: Double
    let screenHeight: Double
    let coordinateSpace: String
    let targets: [VisualTarget]

    enum CodingKeys: String, CodingKey {
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case coordinateSpace = "coordinate_space"
        case targets
    }

    var targetByID: [String: VisualTarget] {
        Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    }

    var jsonObject: [String: Any] {
        let targetObjects = targets.map { target in
            var object = [
                "id": target.id,
                "kind": target.kind.rawValue,
                "role": target.role,
                "box": target.box.asArray,
                "confidence": target.confidence
            ] as [String: Any]
            if let label = target.label {
                object["label"] = label
            }
            return object
        }
        return [
            "screen_width": screenWidth,
            "screen_height": screenHeight,
            "coordinate_space": coordinateSpace,
            "usage_policy": "Optional Accessibility-derived targets. Reason from the raw screenshot first; use target IDs only when they clearly match visible UI. Do not mention target IDs to the user.",
            "targets": targetObjects
        ]
    }
}

struct VisualTarget: Codable {
    let id: String
    let kind: VisualTargetKind
    let role: String
    let label: String?
    let marker: String?
    let box: VisualTargetBox
    let confidence: Double

    var center: CGPoint {
        CGPoint(x: CGFloat(box.x + box.width / 2), y: CGFloat(box.y + box.height / 2))
    }
}

enum VisualTargetKind: String, Codable {
    case appWindow = "app_window"
    case accessibilityElement = "accessibility_element"
}

struct VisualTargetBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var asArray: [Double] { [x, y, width, height] }

    func insetBy(dx: Double, dy: Double) -> VisualTargetBox {
        VisualTargetBox(
            x: x - dx,
            y: y - dy,
            width: width + dx * 2,
            height: height + dy * 2
        )
    }

    func clamped(to screenSize: CGSize) -> VisualTargetBox? {
        let maxWidth = Double(screenSize.width)
        let maxHeight = Double(screenSize.height)
        let minX = max(0, x)
        let minY = max(0, y)
        let maxX = min(maxWidth, x + width)
        let maxY = min(maxHeight, y + height)
        guard maxX > minX, maxY > minY else { return nil }
        return VisualTargetBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
