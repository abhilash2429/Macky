import XCTest
@testable import Macky

final class VisualGuidanceTests: XCTestCase {
    @MainActor
    func testScreenshotPixelsMapToSecondaryDisplayPoints() throws {
        let coordinateSpace = VisualGuidanceCoordinateSpace(
            width: 2_880,
            height: 1_800,
            displayFrame: VisualGuidanceDisplayFrame(
                x: -1_440,
                y: 0,
                width: 1_440,
                height: 900,
                displayID: nil
            )
        )

        let point = try CursorControlIntegration.appKitPoint(
            x: 1_440,
            y: 900,
            coordinateSpace: coordinateSpace
        )

        XCTAssertEqual(point.x, -720, accuracy: 0.001)
        XCTAssertEqual(point.y, 450, accuracy: 0.001)
    }

    func testSequenceRejectsMultipleSpotlightsInOneStep() {
        let spotlight = CanvasCommand(
            type: .spotlight,
            x: 10,
            y: 10,
            width: 100,
            height: 100,
            toX: nil,
            toY: nil,
            points: nil,
            text: nil,
            targetId: nil,
            fromTargetId: nil,
            toTargetId: nil,
            animation: nil
        )
        let sequence = VisualGuidanceSequence(
            title: "Test",
            sourceWidth: 1_000,
            sourceHeight: 800,
            displayFrame: nil,
            steps: [
                VisualGuidanceStep(
                    narrationCue: "Show the target.",
                    durationMs: 4_000,
                    clearBeforeNext: true,
                    canvas: [spotlight, spotlight],
                    cursor: nil
                )
            ]
        )

        XCTAssertThrowsError(try sequence.validated()) { error in
            guard let validationError = error as? VisualGuidanceValidationError,
                  case .tooManySpotlights = validationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSequenceRejectsOverlongNarration() {
        let sequence = VisualGuidanceSequence(
            title: nil,
            sourceWidth: 1_000,
            sourceHeight: 800,
            displayFrame: nil,
            steps: [
                VisualGuidanceStep(
                    narrationCue: String(repeating: "a", count: 241),
                    durationMs: 4_000,
                    clearBeforeNext: true,
                    canvas: [],
                    cursor: CursorCommand(
                        type: .move,
                        x: 100,
                        y: 100,
                        durationMs: 250,
                        label: nil,
                        labelPlacement: nil
                    )
                )
            ]
        )

        XCTAssertThrowsError(try sequence.validated()) { error in
            guard let validationError = error as? VisualGuidanceValidationError,
                  case .narrationCueTooLong = validationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
