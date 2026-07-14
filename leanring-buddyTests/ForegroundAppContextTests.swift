import XCTest
@testable import Macky

final class ForegroundAppContextTests: XCTestCase {
    func testCapturesExternalApplicationIdentity() {
        let context = ForegroundAppContext(
            applicationName: "Slack",
            applicationBundleIdentifier: "com.tinyspeck.slackmacgap",
            currentApplicationBundleIdentifier: "com.speedmac.Macky"
        )

        XCTAssertEqual(context?.applicationName, "Slack")
        XCTAssertEqual(context?.applicationBundleIdentifier, "com.tinyspeck.slackmacgap")
    }

    func testRejectsMackyAsForegroundApplication() {
        let context = ForegroundAppContext(
            applicationName: "Macky",
            applicationBundleIdentifier: "com.speedmac.Macky",
            currentApplicationBundleIdentifier: "com.speedmac.Macky"
        )

        XCTAssertNil(context)
    }

    func testUsesBundleIdentifierWhenApplicationNameIsUnavailable() {
        let context = ForegroundAppContext(
            applicationName: nil,
            applicationBundleIdentifier: "com.apple.Safari",
            currentApplicationBundleIdentifier: "com.speedmac.Macky"
        )

        XCTAssertEqual(context?.applicationName, "com.apple.Safari")
    }

    func testRealtimeMessageContainsOnlyAppIdentityMetadata() {
        let context = try! XCTUnwrap(ForegroundAppContext(
            applicationName: "Safari",
            applicationBundleIdentifier: "com.apple.Safari",
            currentApplicationBundleIdentifier: "com.speedmac.Macky"
        ))

        let message = context.realtimeContextMessage()

        XCTAssertTrue(message.contains("Safari"))
        XCTAssertTrue(message.contains("com.apple.Safari"))
        XCTAssertFalse(message.contains("\"window_title\""))
        XCTAssertFalse(message.contains("\"selected_text\""))
    }
}
