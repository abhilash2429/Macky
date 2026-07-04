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
    }

    func validated() throws -> CanvasCommand {
        switch type {
        case .highlight:
            guard let x, let y, let width, let height, x.isFinite, y.isFinite, width > 0, height > 0 else {
                throw VisualGuidanceValidationError.invalidCanvasCommand
            }
        case .arrow:
            guard let x, let y, let toX, let toY, x.isFinite, y.isFinite, toX.isFinite, toY.isFinite else {
                throw VisualGuidanceValidationError.invalidCanvasCommand
            }
        case .label:
            guard let x, let y, x.isFinite, y.isFinite, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VisualGuidanceValidationError.invalidCanvasCommand
            }
        case .polygon:
            guard let points, points.count >= 3, points.count <= 16, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw VisualGuidanceValidationError.invalidCanvasCommand
            }
        }
        return self
    }
}

enum CanvasCommandType: String, Codable {
    case highlight
    case arrow
    case label
    case polygon
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
    case invalidCanvasCommand
    case invalidCursorCommand

    var errorDescription: String? {
        switch self {
        case .emptySequence:
            return "visual guidance sequence has no steps"
        case .tooManySteps:
            return "visual guidance sequence has too many steps"
        case .emptyStep:
            return "visual guidance step has no canvas or cursor action"
        case .invalidCanvasCommand:
            return "visual guidance canvas command is invalid"
        case .invalidCursorCommand:
            return "visual guidance cursor command is invalid"
        }
    }
}
