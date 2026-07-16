import XCTest
@testable import Macky

final class DictationFocusPreparationPolicyTests: XCTestCase {
    func testRetriesOnlyTransientFocusedFieldFailures() {
        XCTAssertTrue(
            DictationFocusPreparationPolicy.shouldRetry(.noFocusedField, isBrowser: false)
        )
        XCTAssertTrue(
            DictationFocusPreparationPolicy.shouldRetry(.browserPageTextNotEditable, isBrowser: true)
        )
        XCTAssertTrue(
            DictationFocusPreparationPolicy.shouldRetry(.fieldIsNotWritable, isBrowser: true)
        )

        XCTAssertFalse(
            DictationFocusPreparationPolicy.shouldRetry(.browserPageTextNotEditable, isBrowser: false)
        )
        XCTAssertFalse(
            DictationFocusPreparationPolicy.shouldRetry(.secureField, isBrowser: true)
        )
        XCTAssertFalse(
            DictationFocusPreparationPolicy.shouldRetry(.focusChangedBeforeRecording, isBrowser: true)
        )
    }
}
