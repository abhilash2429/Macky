//
//  DictationTargetIntegration.swift
//  leanring-buddy
//
//  A deliberately narrow Accessibility path for dictation. Preparation reads
//  only the local target identity needed to safely revalidate later; it never
//  exposes a field value, selection text, title, or browser metadata to the
//  dictation backend.
//

import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class DictationTargetIntegration {
    private static let snapshotLifetime: TimeInterval = 180
    private static let maximumEditableValueLength = 32_000

    private struct Snapshot {
        let applicationName: String
        let applicationBundleIdentifier: String
        let applicationProcessIdentifier: pid_t
        let element: AXUIElement
        let role: String
        let frame: CGRect?
        let originalValue: String?
        let selectedRange: CFRange?
        let isTerminal: Bool
        let requiresPaste: Bool
        let preparation: DictationTargetPreparation
        let capturedAt: Date
    }

    private var snapshot: Snapshot?

    func prepareTarget() async throws -> DictationTargetPreparation {
        let captured = try await captureSnapshot()
        snapshot = captured
        return captured.preparation
    }

    func insertFinalText(_ text: String) async throws -> FocusedEditPresentation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictationTargetError.emptyText }
        guard let snapshot else { throw DictationTargetError.snapshotUnavailable }

        try validate(snapshot, expectedValue: snapshot.requiresPaste ? nil : snapshot.originalValue)
        if snapshot.isTerminal {
            try await paste(text, into: snapshot, expectedValue: nil)
            self.snapshot = nil
            return FocusedEditPresentation(
                kind: .terminalCommand,
                applicationName: snapshot.applicationName,
                insertedText: text,
                summary: "Staged dictation in \(snapshot.applicationName)",
                detail: "Not run. Review it in Terminal, then press Return when you are ready.",
                canUndo: false
            )
        }

        if snapshot.requiresPaste {
            try await paste(text, into: snapshot, expectedValue: nil)
            self.snapshot = nil
            return FocusedEditPresentation(
                kind: .textEdit,
                applicationName: snapshot.applicationName,
                insertedText: text,
                summary: snapshot.preparation.hasSelection ? "Replaced selected text" : "Inserted dictated text",
                detail: "Inserted into the verified focused field. Review it before sending.",
                canUndo: false
            )
        }

        guard let originalValue = snapshot.originalValue else {
            throw DictationTargetError.fieldIsNotWritable
        }
        let updatedValue = try applying(text, to: originalValue, selectedRange: snapshot.selectedRange)
        let writeResult = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard writeResult == .success,
              stringAttribute(kAXValueAttribute, from: snapshot.element) == updatedValue else {
            throw DictationTargetError.writeCouldNotBeVerified
        }

        self.snapshot = nil
        return FocusedEditPresentation(
            kind: .textEdit,
            applicationName: snapshot.applicationName,
            insertedText: text,
            summary: snapshot.preparation.hasSelection ? "Replaced selected text" : "Inserted dictated text",
            detail: "Inserted into the verified focused field.",
            canUndo: false
        )
    }

    func discardPreparation() {
        snapshot = nil
    }

    private func captureSnapshot() async throws -> Snapshot {
        guard AXIsProcessTrusted() else {
            throw DictationTargetError.accessibilityPermissionRequired
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw DictationTargetError.noExternalFocusedApplication
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let isBrowser = DictationSurfaceClassifier.isBrowser(bundleIdentifier: bundleIdentifier)
        if isBrowser {
            enableBrowserAccessibility(for: applicationElement)
            try await Task.sleep(for: .milliseconds(120))
        }
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement) else {
            throw DictationTargetError.noFocusedField
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? "unknown"
        let subrole = stringAttribute(kAXSubroleAttribute, from: element) ?? ""
        guard !isSecureField(role: role, subrole: subrole) else {
            throw DictationTargetError.secureField
        }

        let isTerminal = DictationSurfaceClassifier.isTerminal(bundleIdentifier: bundleIdentifier)
        let value = isTerminal ? nil : stringAttribute(kAXValueAttribute, from: element)
        if let value, value.count > Self.maximumEditableValueLength {
            throw DictationTargetError.fieldIsTooLarge
        }
        let selectedRange = selectedRange(from: element)
        let isTextRole = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
        let isEditable = boolAttribute(kAXIsEditableAttribute, from: element) ?? isTextRole
        guard isEditable || isTerminal else {
            throw isBrowser ? DictationTargetError.browserPageTextNotEditable : DictationTargetError.fieldIsNotWritable
        }

        // Browser strings are classified only locally. They are intentionally not
        // stored in the preparation, logged, or included in any Worker message.
        let browserMetadata = isBrowser ? localBrowserMetadata(from: applicationElement, focusedElement: element) : []
        let surfaceKind = DictationSurfaceClassifier.classify(
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? bundleIdentifier,
            browserMetadata: browserMetadata
        )
        let hasSelection = selectedRange.map { $0.location != kCFNotFound && $0.length > 0 } ?? false
        let preparation = DictationTargetPreparation(
            applicationName: application.localizedName ?? bundleIdentifier,
            applicationBundleIdentifier: bundleIdentifier,
            surfaceKind: surfaceKind,
            hasSelection: hasSelection,
            isTerminal: isTerminal
        )

        return Snapshot(
            applicationName: preparation.applicationName,
            applicationBundleIdentifier: bundleIdentifier,
            applicationProcessIdentifier: application.processIdentifier,
            element: element,
            role: role,
            frame: frame(from: element),
            originalValue: value,
            selectedRange: selectedRange,
            isTerminal: isTerminal,
            requiresPaste: !isTerminal && (isBrowser || !isAttributeSettable(kAXValueAttribute, on: element)),
            preparation: preparation,
            capturedAt: Date()
        )
    }

    private func validate(_ snapshot: Snapshot, expectedValue: String? = nil) throws {
        guard Date().timeIntervalSince(snapshot.capturedAt) <= Self.snapshotLifetime else {
            throw DictationTargetError.snapshotExpired
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == snapshot.applicationProcessIdentifier,
              application.bundleIdentifier == snapshot.applicationBundleIdentifier else {
            throw DictationTargetError.focusChanged
        }

        let applicationElement = AXUIElementCreateApplication(snapshot.applicationProcessIdentifier)
        guard let currentElement = elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement),
              sameElement(snapshot.element, currentElement),
              stringAttribute(kAXRoleAttribute, from: currentElement) == snapshot.role,
              frame(from: currentElement) == snapshot.frame,
              selectionStillMatches(snapshot, currentElement: currentElement) else {
            throw DictationTargetError.focusChanged
        }
        if let expectedValue,
           stringAttribute(kAXValueAttribute, from: currentElement) != expectedValue {
            throw DictationTargetError.fieldChanged
        }
    }

    private func applying(_ text: String, to originalValue: String, selectedRange: CFRange?) throws -> String {
        guard let selectedRange,
              selectedRange.location != kCFNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              let range = Range(NSRange(location: selectedRange.location, length: selectedRange.length), in: originalValue) else {
            throw DictationTargetError.cursorUnavailable
        }
        return originalValue.replacingCharacters(in: range, with: text)
    }

    private func paste(_ text: String, into snapshot: Snapshot, expectedValue: String?) async throws {
        try validate(snapshot, expectedValue: expectedValue)
        let pasteboard = NSPasteboard.general
        let originalItems = copyPasteboardItems(pasteboard.pasteboardItems)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // `clearContents` already changed the pasteboard. Restore the prior
            // clipboard unless another app changed it while this write failed.
            restorePasteboard(originalItems, onlyIfChangeCount: pasteboard.changeCount)
            throw DictationTargetError.pasteFailed
        }
        let mackyPasteboardChangeCount = pasteboard.changeCount

        do {
            try validate(snapshot, expectedValue: expectedValue)
            try postPasteShortcut()
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            restorePasteboard(originalItems, onlyIfChangeCount: mackyPasteboardChangeCount)
            throw error
        }
        restorePasteboard(originalItems, onlyIfChangeCount: mackyPasteboardChangeCount)
    }

    private func selectionStillMatches(_ snapshot: Snapshot, currentElement: AXUIElement) -> Bool {
        guard !snapshot.isTerminal else { return true }
        guard let expected = snapshot.selectedRange else { return true }
        guard let current = selectedRange(from: currentElement) else { return false }
        return current.location == expected.location && current.length == expected.length
    }

    private func localBrowserMetadata(from applicationElement: AXUIElement, focusedElement: AXUIElement) -> [String] {
        var metadata = [String]()
        if let window = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement) {
            metadata.append(contentsOf: [
                stringAttribute(kAXTitleAttribute, from: window),
                stringAttribute("AXDocument", from: window),
                stringAttribute(kAXDescriptionAttribute, from: window),
            ].compactMap { $0 })
        }
        metadata.append(contentsOf: [
            stringAttribute(kAXDescriptionAttribute, from: focusedElement),
            stringAttribute(kAXTitleAttribute, from: focusedElement),
        ].compactMap { $0 })
        return metadata
    }

    private func enableBrowserAccessibility(for applicationElement: AXUIElement) {
        _ = AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
        if let window = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement) {
            _ = AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        }
    }

    private func isSecureField(role: String, subrole: String) -> Bool {
        (role == kAXTextFieldRole as String && subrole == kAXSecureTextFieldSubrole as String)
            || subrole.localizedCaseInsensitiveContains("secure")
    }

    private func sameElement(_ first: AXUIElement, _ second: AXUIElement) -> Bool {
        CFEqual(first, second)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func selectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange(location: kCFNotFound, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func frame(from element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func copyPasteboardItems(_ items: [NSPasteboardItem]?) -> [NSPasteboardItem] {
        (items ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(_ originalItems: [NSPasteboardItem], onlyIfChangeCount expectedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
        if !originalItems.isEmpty {
            _ = pasteboard.writeObjects(originalItems)
        }
    }

    private func postPasteShortcut() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw DictationTargetError.pasteFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private enum DictationTargetError: LocalizedError {
    case accessibilityPermissionRequired
    case noExternalFocusedApplication
    case noFocusedField
    case secureField
    case fieldIsNotWritable
    case browserPageTextNotEditable
    case fieldIsTooLarge
    case snapshotUnavailable
    case snapshotExpired
    case focusChanged
    case fieldChanged
    case cursorUnavailable
    case emptyText
    case writeCouldNotBeVerified
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Dictation needs Accessibility permission to validate the focused field."
        case .noExternalFocusedApplication:
            return "Focus an app outside Macky, then try dictation again."
        case .noFocusedField:
            return "Focus an editable text field or Terminal prompt before dictating."
        case .secureField:
            return "Macky never records for secure text fields."
        case .fieldIsNotWritable:
            return "The focused control is not a writable text field."
        case .browserPageTextNotEditable:
            return "The focused browser content is not editable. Focus a composer or text field first."
        case .fieldIsTooLarge:
            return "The focused field is too large to validate safely. Select the intended text first."
        case .snapshotUnavailable:
            return "The focused field must be checked again before dictation can insert text."
        case .snapshotExpired:
            return "Dictation took too long; the focused field was not changed."
        case .focusChanged:
            return "Focus changed, so Macky did not type into a new field."
        case .fieldChanged:
            return "The focused field changed while dictating, so Macky did not overwrite it."
        case .cursorUnavailable:
            return "Macky could not verify the insertion cursor."
        case .emptyText:
            return "Macky did not hear text to insert."
        case .writeCouldNotBeVerified:
            return "Macky could not verify the dictation insertion."
        case .pasteFailed:
            return "Macky could not paste into the verified field."
        }
    }
}
