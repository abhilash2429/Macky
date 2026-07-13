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

struct VisualGuidanceDisplayFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let displayID: UInt32?

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
        case displayID = "display_id"
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct VisualGuidanceCoordinateSpace: Codable {
    let width: Double
    let height: Double
    let displayFrame: VisualGuidanceDisplayFrame?

    var cgSize: CGSize {
        CGSize(width: max(1, width), height: max(1, height))
    }
}

/// Local-only presentation context. The vision model owns drawing coordinates, while
/// the app owns the exact display and application identity those coordinates came from.
struct VisualGuidancePresentation {
    let sequence: VisualGuidanceSequence
    let sourceApplicationBundleIdentifier: String?
    let capturedAt: Date
}

struct CursorLabelPresentation {
    let command: CursorCommand
    let coordinateSpace: VisualGuidanceCoordinateSpace
    let displayDurationNanoseconds: UInt64
}

struct VisualGuidanceSequence: Codable {
    let title: String?
    let sourceWidth: Double?
    let sourceHeight: Double?
    let displayFrame: VisualGuidanceDisplayFrame?
    /// When true, the app pings the realtime model after the user performs the final
    /// on_user_action step, so it can re-capture the changed screen and continue the guide.
    let continueAfterUserAction: Bool?
    let steps: [VisualGuidanceStep]

    enum CodingKeys: String, CodingKey {
        case title
        case sourceWidth = "source_width"
        case sourceHeight = "source_height"
        case displayFrame = "display_frame"
        case continueAfterUserAction = "continue_after_user_action"
        case steps
    }

    var coordinateSpace: VisualGuidanceCoordinateSpace? {
        guard let sourceWidth, let sourceHeight, sourceWidth > 0, sourceHeight > 0 else {
            return nil
        }
        return VisualGuidanceCoordinateSpace(width: sourceWidth, height: sourceHeight, displayFrame: displayFrame)
    }

    var usesTargetReferences: Bool {
        steps.contains { step in
            step.canvas.contains { $0.usesTargetReferences }
        }
    }

    func validated(maxSteps: Int = 12) throws -> VisualGuidanceSequence {
        guard !steps.isEmpty else { throw VisualGuidanceValidationError.emptySequence }
        guard steps.count <= maxSteps else { throw VisualGuidanceValidationError.tooManySteps }
        if let title {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count <= 120 else {
                throw VisualGuidanceValidationError.invalidTitle
            }
        }
        if sourceWidth != nil || sourceHeight != nil {
            guard let sourceWidth, let sourceHeight,
                  sourceWidth.isFinite, sourceHeight.isFinite,
                  sourceWidth > 0, sourceHeight > 0,
                  sourceWidth <= 16_384, sourceHeight <= 16_384 else {
                throw VisualGuidanceValidationError.sourceDimensionMismatch
            }
        }
        if let displayFrame {
            guard displayFrame.x.isFinite, displayFrame.y.isFinite,
                  displayFrame.width.isFinite, displayFrame.height.isFinite,
                  displayFrame.width > 0, displayFrame.height > 0 else {
                throw VisualGuidanceValidationError.invalidDisplayFrame
            }
        }
        // Interactive waits are only allowed as the final step so playback stays
        // "show steps, then wait once for the user's click"; richer interaction goes
        // through the continuation loop with a fresh screenshot. Mirrors the Worker rule.
        let interactiveStepIndices = steps.indices.filter { steps[$0].advanceMode == .onUserAction }
        guard interactiveStepIndices.count <= 1,
              interactiveStepIndices.first.map({ $0 == steps.count - 1 }) ?? true else {
            throw VisualGuidanceValidationError.invalidInteractiveStep
        }
        if continueAfterUserAction == true {
            guard steps.last?.advanceMode == .onUserAction else {
                throw VisualGuidanceValidationError.invalidInteractiveStep
            }
        }
        return VisualGuidanceSequence(
            title: title,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            displayFrame: displayFrame,
            continueAfterUserAction: continueAfterUserAction,
            steps: try steps.map { try $0.validated() }
        )
    }
}

/// How a step yields to the next one: on a timer, or when the user performs the
/// indicated action (a click detected by a global event monitor).
enum VisualGuidanceStepAdvance: String, Codable {
    case timed
    case onUserAction = "on_user_action"
}

struct VisualGuidanceStep: Codable {
    let narrationCue: String?
    let durationMs: Int?
    let clearBeforeNext: Bool?
    let advance: VisualGuidanceStepAdvance?
    let canvas: [CanvasCommand]
    let cursor: CursorCommand?

    private static let maxCanvasCommands = 8

    enum CodingKeys: String, CodingKey {
        case narrationCue = "narration_cue"
        case durationMs = "duration_ms"
        case clearBeforeNext = "clear_before_next"
        case advance
        case canvas
        case cursor
    }

    var advanceMode: VisualGuidanceStepAdvance { advance ?? .timed }

    var displayDurationNanoseconds: UInt64 {
        let clampedMs = min(max(durationMs ?? 5_500, 4_000), 20_000)
        return UInt64(clampedMs) * 1_000_000
    }

    func validated() throws -> VisualGuidanceStep {
        guard !canvas.isEmpty || cursor != nil else { throw VisualGuidanceValidationError.emptyStep }
        guard canvas.count <= Self.maxCanvasCommands else { throw VisualGuidanceValidationError.tooManyCanvasCommands }
        guard canvas.filter({ $0.type == .spotlight }).count <= 1 else {
            throw VisualGuidanceValidationError.tooManySpotlights
        }
        guard durationMs == nil || (durationMs! >= 4_000 && durationMs! <= 20_000) else {
            throw VisualGuidanceValidationError.invalidStepDuration
        }
        if let narrationCue {
            guard !narrationCue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VisualGuidanceValidationError.emptyNarrationCue
            }
            guard narrationCue.count <= 240 else {
                throw VisualGuidanceValidationError.narrationCueTooLong
            }
        }
        return VisualGuidanceStep(
            narrationCue: narrationCue,
            durationMs: durationMs,
            clearBeforeNext: clearBeforeNext,
            advance: advance,
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

    var usesTargetReferences: Bool {
        targetId?.isEmpty == false || fromTargetId?.isEmpty == false || toTargetId?.isEmpty == false
    }

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
            guard (hasDirectPoint || hasTarget), let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 120 else {
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
        min(max(repeatCount ?? 1, 1), 5)
    }

    func validated() throws -> CanvasAnimation {
        guard durationMs == nil || (durationMs! >= 100 && durationMs! <= 2_500) else {
            throw VisualGuidanceValidationError.invalidAnimation
        }
        guard delayMs == nil || (delayMs! >= 0 && delayMs! <= 1_500) else {
            throw VisualGuidanceValidationError.invalidAnimation
        }
        guard repeatCount == nil || (repeatCount! >= 1 && repeatCount! <= 5) else {
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
    let label: String?
    let labelPlacement: CursorLabelPlacement?

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case durationMs = "duration_ms"
        case label
        case labelPlacement = "label_placement"
    }

    var duration: TimeInterval {
        TimeInterval(min(max(durationMs ?? 450, 100), 2_000)) / 1_000
    }

    func validated() throws -> CursorCommand {
        guard x.isFinite, y.isFinite else { throw VisualGuidanceValidationError.invalidCursorCommand }
        guard durationMs == nil || (durationMs! >= 100 && durationMs! <= 2_000) else {
            throw VisualGuidanceValidationError.invalidCursorCommand
        }
        if let label {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  label.count <= 80 else {
                throw VisualGuidanceValidationError.invalidCursorCommand
            }
        }
        return self
    }
}

/// Label position relative to the cursor point. The renderer clamps the label onto screen.
enum CursorLabelPlacement: String, Codable {
    case above
    case below
    case left
    case right
    case aboveRight = "above_right"
    case belowRight = "below_right"
    case aboveLeft = "above_left"
    case belowLeft = "below_left"
}

enum CursorCommandType: String, Codable {
    case move
}

enum VisualGuidanceValidationError: LocalizedError {
    case emptySequence
    case tooManySteps
    case emptyStep
    case tooManyCanvasCommands
    case tooManySpotlights
    case invalidStepDuration
    case invalidInteractiveStep
    case emptyNarrationCue
    case narrationCueTooLong
    case invalidTitle
    case invalidDisplayFrame
    case invalidCanvasCommand
    case invalidCursorCommand
    case invalidAnimation
    case sourceDimensionMismatch
    case staleScreenCapture
    case coordinateOutOfBounds(String)
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
        case .tooManySpotlights:
            return "visual guidance step can contain at most one spotlight"
        case .invalidStepDuration:
            return "visual guidance step duration is invalid"
        case .invalidInteractiveStep:
            return "visual guidance allows at most one on_user_action step, only as the final step, and continue_after_user_action requires it"
        case .emptyNarrationCue:
            return "visual guidance narration cue is empty"
        case .narrationCueTooLong:
            return "visual guidance narration cue is too long"
        case .invalidTitle:
            return "visual guidance title is invalid"
        case .invalidDisplayFrame:
            return "visual guidance display frame is invalid"
        case .invalidCanvasCommand:
            return "visual guidance canvas command is invalid"
        case .invalidCursorCommand:
            return "visual guidance cursor command is invalid"
        case .invalidAnimation:
            return "visual guidance animation is invalid"
        case .sourceDimensionMismatch:
            return "visual guidance source dimensions do not match the latest screenshot"
        case .staleScreenCapture:
            return "visual guidance needs a fresh screenshot for the current request; call get_screen_context first, then retry"
        case .coordinateOutOfBounds(let detail):
            return "visual guidance coordinates are outside the latest screenshot coordinate space: \(detail). Retry using coordinates within the latest screenshot bounds."
        case .visualSceneUnavailable:
            return "target IDs need visual_scene metadata; use raw screenshot coordinates instead"
        case .missingVisualTarget(let targetId):
            return "visual guidance target not found: \(targetId)"
        }
    }
}
