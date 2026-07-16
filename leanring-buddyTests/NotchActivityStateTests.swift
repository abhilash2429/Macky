import XCTest
@testable import Macky

final class NotchActivityStateTests: XCTestCase {
    func testDictationStatesOverrideAssistantActivity() {
        XCTAssertEqual(
            NotchActivityState.resolve(
                voiceState: .listening,
                operationState: .thinking,
                dictationLifecycle: .connecting,
                toolCallActive: true
            ),
            .dictationConnecting
        )
    }

    func testAssistantStateResolverDistinguishesThinkingWorkSpeechAndFailure() {
        XCTAssertEqual(
            NotchActivityState.resolve(
                voiceState: .processing,
                operationState: .thinking,
                dictationLifecycle: .idle,
                toolCallActive: false
            ),
            .thinking
        )
        XCTAssertEqual(
            NotchActivityState.resolve(
                voiceState: .responding,
                operationState: .speaking,
                dictationLifecycle: .idle,
                toolCallActive: true
            ),
            .executing
        )
        XCTAssertEqual(
            NotchActivityState.resolve(
                voiceState: .idle,
                operationState: .error("network unavailable"),
                dictationLifecycle: .idle,
                toolCallActive: false
            ),
            .failure
        )
    }
}
