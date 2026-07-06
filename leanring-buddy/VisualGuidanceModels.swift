//
//  VisualGuidanceModels.swift
//  leanring-buddy
//
//  Typed payloads for Macky's screen teaching overlay. Coordinates are expressed
//  in the source screenshot's top-left coordinate space; renderers convert them
//  to the current main-screen overlay bounds before drawing or moving the cursor.
//

import CoreGraphics
import Foundation

struct VisualGuidanceCoordinateSpace: Codable {
    let width: Double
    let height: Double

    var cgSize: CGSize {
        CGSize(width: max(1, width), height: max(1, height))
    }
}

struct VisualGuidanceSequence: Codable {
    let title: String?
    let sourceWidth: Double?
    let sourceHeight: Double?
    let steps: [VisualGuidanceStep]

    enum CodingKeys: String, CodingKey {
        case title
        case sourceWidth = "source_width"
        case sourceHeight = "source_height"
        case steps
    }

    var coordinateSpace: VisualGuidanceCoordinateSpace? {
        guard let sourceWidth, let sourceHeight, sourceWidth > 0, sourceHeight > 0 else {
            return nil
        }
        return VisualGuidanceCoordinateSpace(width: sourceWidth, height: sourceHeight)
    }

    func validated(maxSteps: Int = 12) throws -> VisualGuidanceSequence {
        guard !steps.isEmpty else { throw VisualGuidanceValidationError.emptySequence }
        guard steps.count <= maxSteps else { throw VisualGuidanceValidationError.tooManySteps }
        return VisualGuidanceSequence(
            title: title,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            steps: try steps.map { try $0.validated() }
        )
    }
}

struct VisualGuidanceStep: Codable {
    let narrationCue: String?
    let durationMs: Int?
    let clearBeforeNext: Bool?
    let canvas: [CanvasCommand]
    let cursor: CursorCommand?

    private static let maxCanvasCommands = 8

    enum CodingKeys: String, CodingKey {
        case narrationCue = "narration_cue"
        case durationMs = "duration_ms"
        case clearBeforeNext = "clear_before_next"
        case canvas
        case cursor
    }

    var displayDurationNanoseconds: UInt64 {
        let clampedMs = min(max(durationMs ?? 2200, 500), 12_000)
        return UInt64(clampedMs) * 1_000_000
    }

    func validated() throws -> VisualGuidanceStep {
        guard !canvas.isEmpty || cursor != nil else { throw VisualGuidanceValidationError.emptyStep }
        guard canvas.count <= Self.maxCanvasCommands else { throw VisualGuidanceValidationError.tooManyCanvasCommands }
        return VisualGuidanceStep(
            narrationCue: narrationCue,
            durationMs: durationMs,
            clearBeforeNext: clearBeforeNext,
            canvas: try canvas.map { try $0.validated() },
            cursor: try cursor?.validated()
        )
    }
}

struct CanvasCommand: Codable {
    let type: CanvasCommandType
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let toX: Double?
    let toY: Double?
    let points: [CanvasPoint]?
    let text: String?
    let targetId: String?
    let fromTargetId: String?
    let toTargetId: String?
    let animation: CanvasAnimation?

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case width
        case height
        case toX = "to_x"
        case toY = "to_y"
        case points
        case text
        case targetId = "target_id"
        case fromTargetId = "from_target_id"
        case toTargetId = "to_target_id"
        case animation
    }

    func validated() throws -> CanvasCommand {
        switch type {
        case .highlight, .circle, .ring, .spotlight, .brace:
            let hasDirectBox = x?.isFinite == true && y?.isFinite == true && (width ?? 0) > 0 && (height ?? 0) > 0
            let hasTarget = targetId?.isEmpty == false
            guard hasDirectBox || hasTarget else { throw VisualGuidanceValidationError.invalidCanvasCommand }
        case .arrow, .line:
            let hasDirectPoints = x?.isFinite == true && y?.isFinite == true && toX?.isFinite == true && toY?.isFinite == true
            let hasTargets = fromTargetId?.isEmpty == false && toTargetId?.isEmpty == false
            guard hasDirectPoints || hasTargets else { throw VisualGuidanceValidationError.invalidCanvasCommand }
        case .label:
            let hasDirectPoint = x?.isFinite == true && y?.isFinite == true
            let hasTarget = targetId?.isEmpty == false
            guard (hasDirectPoint || hasTarget), let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VisualGuidanceValidationError.invalidCanvasCommand
            }
        case .polygon:
            guard let points, points.count >= 3, points.count <= 16, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw VisualGuidanceValidationError.invalidCanvasCommand
            }
        }
        _ = try animation?.validated()
        return self
    }
}

struct CanvasAnimation: Codable {
    let type: CanvasAnimationType
    let durationMs: Int?
    let delayMs: Int?
    let repeatCount: Int?
    let easing: CanvasAnimationEasing?

    enum CodingKeys: String, CodingKey {
        case type
        case durationMs = "duration_ms"
        case delayMs = "delay_ms"
        case repeatCount = "repeat"
        case easing
    }

    var duration: Double {
        Double(min(max(durationMs ?? 550, 100), 2_500)) / 1_000
    }

    var delay: Double {
        Double(min(max(delayMs ?? 0, 0), 1_500)) / 1_000
    }

    var repetitions: Int {
        min(max(repeatCount ?? 1, 0), 5)
    }

    func validated() throws -> CanvasAnimation {
        guard durationMs == nil || (durationMs! >= 100 && durationMs! <= 2_500) else {
            throw VisualGuidanceValidationError.invalidAnimation
        }
        guard delayMs == nil || (delayMs! >= 0 && delayMs! <= 1_500) else {
            throw VisualGuidanceValidationError.invalidAnimation
        }
        guard repeatCount == nil || (repeatCount! >= 0 && repeatCount! <= 5) else {
            throw VisualGuidanceValidationError.invalidAnimation
        }
        return self
    }
}

enum CanvasAnimationType: String, Codable {
    case none
    case fadeIn = "fade_in"
    case scaleIn = "scale_in"
    case pulse
    case draw
    case travel
    case dashFlow = "dash_flow"
}

enum CanvasAnimationEasing: String, Codable {
    case linear
    case easeIn = "ease_in"
    case easeOut = "ease_out"
    case easeInOut = "ease_in_out"
}

enum CanvasCommandType: String, Codable {
    case highlight
    case arrow
    case label
    case polygon
    case circle
    case ring
    case spotlight
    case line
    case brace
}

struct CanvasPoint: Codable {
    let x: Double
    let y: Double
}

struct CursorCommand: Codable {
    let type: CursorCommandType
    let x: Double
    let y: Double
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case durationMs = "duration_ms"
    }

    var duration: TimeInterval {
        TimeInterval(min(max(durationMs ?? 450, 100), 2_000)) / 1_000
    }

    func validated() throws -> CursorCommand {
        guard x.isFinite, y.isFinite else { throw VisualGuidanceValidationError.invalidCursorCommand }
        return self
    }
}

enum CursorCommandType: String, Codable {
    case move
    case click
}

enum VisualGuidanceValidationError: LocalizedError {
    case emptySequence
    case tooManySteps
    case emptyStep
    case tooManyCanvasCommands
    case invalidCanvasCommand
    case invalidCursorCommand
    case invalidAnimation
    case sourceDimensionMismatch
    case visualSceneUnavailable
    case missingVisualTarget(String)

    var errorDescription: String? {
        switch self {
        case .emptySequence:
            return "visual guidance sequence has no steps"
        case .tooManySteps:
            return "visual guidance sequence has too many steps"
        case .emptyStep:
            return "visual guidance step has no canvas or cursor action"
        case .tooManyCanvasCommands:
            return "visual guidance step has too many canvas commands"
        case .invalidCanvasCommand:
            return "visual guidance canvas command is invalid"
        case .invalidCursorCommand:
            return "visual guidance cursor command is invalid"
        case .invalidAnimation:
            return "visual guidance animation is invalid"
        case .sourceDimensionMismatch:
            return "visual guidance source dimensions do not match the latest main-display screenshot"
        case .visualSceneUnavailable:
            return "call get_screen_context without all_screens before drawing visual overlays"
        case .missingVisualTarget(let targetId):
            return "visual guidance target not found: \(targetId)"
        }
    }
}
