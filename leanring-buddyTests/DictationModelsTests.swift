import AppKit
import XCTest
@testable import Macky

final class DictationModelsTests: XCTestCase {
    func testClassifiesGmailAndSlackFromLocalBrowserMetadata() {
        XCTAssertEqual(
            DictationSurfaceClassifier.classify(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                browserMetadata: ["Inbox - Gmail", "https://mail.google.com/mail"]
            ),
            .email
        )
        XCTAssertEqual(
            DictationSurfaceClassifier.classify(
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                browserMetadata: ["Slack | team", "https://app.slack.com/client"]
            ),
            .chat
        )
    }

    func testClassifiesTerminalAndCodeWithoutWindowMetadata() {
        XCTAssertEqual(
            DictationSurfaceClassifier.classify(
                bundleIdentifier: "com.apple.Terminal",
                applicationName: "Terminal"
            ),
            .terminal
        )
        XCTAssertEqual(
            DictationSurfaceClassifier.classify(
                bundleIdentifier: "com.microsoft.VSCode",
                applicationName: "Visual Studio Code"
            ),
            .code
        )
    }

    func testCleanModeKeepsMeaningfulLikeWhileRemovingIsolatedFiller() {
        let result = LocalDictationFormatter.format(
            transcript: "I like this uh new paragraph bullet keep like this period",
            mode: .clean,
            surfaceKind: .generic
        )

        XCTAssertTrue(result.contains("I like this"))
        XCTAssertTrue(result.contains("keep like this."))
        XCTAssertFalse(result.contains(" uh "))
        XCTAssertTrue(result.contains("•"))
    }

    func testLiteralModeDoesNotRemoveFillers() {
        let result = LocalDictationFormatter.format(
            transcript: "um keep this like it is",
            mode: .literal,
            surfaceKind: .generic
        )

        XCTAssertTrue(result.contains("um"))
        XCTAssertTrue(result.contains("like"))
    }

    func testGlossaryDeduplicatesAndEnforcesProviderLimits() {
        let source = (["Macky", "macky", "api.example.com"] + (0..<130).map { "term\($0)" })
            .joined(separator: "\n")
        let terms = DictationGlossary.keyterms(from: source)

        XCTAssertEqual(terms.first, "Macky")
        XCTAssertEqual(terms.filter { $0.caseInsensitiveCompare("macky") == .orderedSame }.count, 1)
        XCTAssertEqual(terms.count, DictationGlossary.maximumTerms)
    }

    func testAssistantHotkeyCannotUseReservedDictationChord() {
        let dictationChord = HotkeyConfiguration(modifierFlags: [.control, .function])
        XCTAssertEqual(dictationChord.modifierFlags, HotkeyConfiguration.reservedDictationModifierFlags)
        XCTAssertTrue(HotkeyConfiguration.conflictsWithReservedDictationShortcut([.control]))
        XCTAssertTrue(HotkeyConfiguration.conflictsWithReservedDictationShortcut([.control, .function, .option]))
        XCTAssertNotEqual(HotkeyConfiguration.default.modifierFlags, dictationChord.modifierFlags)
    }
}
