//
//  FocusedTextIntegration.swift
//  leanring-buddy
//
//  A local, Accessibility-backed editor for the control the user already has
//  focused. It deliberately works from short-lived snapshots so Macky never
//  writes into a field after the user has moved to a different app or control.
//

import AppKit
import ApplicationServices
import Carbon
import Foundation

enum FocusedTextEditOperation: String {
    case replaceSelection = "replace_selection"
    case insertAtCursor = "insert_at_cursor"
    case replaceField = "replace_field"
}

struct FocusedEditPresentation: Identifiable, Equatable {
    enum Kind: String {
        case textEdit
        case terminalCommand
        case safetyNotice
        case undo
    }

    let id: UUID
    let kind: Kind
    let applicationName: String
    let windowTitle: String?
    let originalText: String?
    let insertedText: String?
    let summary: String
    let detail: String
    let canUndo: Bool
    let shouldAutoExpand: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        applicationName: String,
        windowTitle: String? = nil,
        originalText: String? = nil,
        insertedText: String? = nil,
        summary: String,
        detail: String,
        canUndo: Bool,
        shouldAutoExpand: Bool,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.originalText = originalText
        self.insertedText = insertedText
        self.summary = summary
        self.detail = detail
        self.canUndo = canUndo
        self.shouldAutoExpand = shouldAutoExpand
        self.timestamp = timestamp
    }

    var iconName: String {
        switch kind {
        case .textEdit: return "pencil.line"
        case .terminalCommand: return "terminal"
        case .safetyNotice: return "exclamationmark.triangle"
        case .undo: return "arrow.uturn.backward"
        }
    }

    var title: String {
        switch kind {
        case .textEdit: return "Edited focused text"
        case .terminalCommand: return "Command staged"
        case .safetyNotice: return "Text edit paused"
        case .undo: return "Edit undone"
        }
    }
}

struct FocusedTextContext {
    let snapshotID: UUID
    let applicationName: String
    let applicationBundleIdentifier: String
    let windowTitle: String?
    let fieldRole: String
    let selectedText: String?
    let canReplaceSelection: Bool
    let canInsertAtCursor: Bool
    let isTerminal: Bool

    func jsonString() -> String {
        let object: [String: Any] = [
            "snapshot_id": snapshotID.uuidString,
            "application_name": applicationName,
            "application_bundle_identifier": applicationBundleIdentifier,
            "window_title": windowTitle ?? NSNull(),
            "field_role": fieldRole,
            "selected_text": selectedText ?? "",
            "has_selection": !(selectedText ?? "").isEmpty,
            "can_replace_selection": canReplaceSelection,
            "can_insert_at_cursor": canInsertAtCursor,
            "is_terminal": isTerminal,
            "terminal_execution_allowed": false,
        ]
        return Self.serialized(object)
    }

    private static func serialized(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not serialize focused field context\"}"
        }
        return string
    }
}

@MainActor
final class FocusedTextIntegration {
    private static let snapshotLifetime: TimeInterval = 8
    private static let undoLifetime: TimeInterval = 30
    private static let maxEditableValueLength = 32_000
    private static let maxSelectedTextLength = 4_000
    private static let knownTerminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
    ]

    private struct Snapshot {
        let id: UUID
        let applicationName: String
        let applicationBundleIdentifier: String
        let applicationProcessIdentifier: pid_t
        let windowTitle: String?
        let element: AXUIElement
        let role: String
        let frame: CGRect?
        let originalValue: String?
        let selectedRange: CFRange?
        let selectedText: String?
        let isTerminal: Bool
        let capturedAt: Date
    }

    private struct UndoTransaction {
        let snapshot: Snapshot
        let updatedValue: String
        let createdAt: Date
    }

    private var snapshots: [UUID: Snapshot] = [:]
    private var undoTransaction: UndoTransaction?

    func inspectFocusedField() throws -> FocusedTextContext {
        let snapshot = try captureSnapshot()
        snapshots = [snapshot.id: snapshot]

        return FocusedTextContext(
            snapshotID: snapshot.id,
            applicationName: snapshot.applicationName,
            applicationBundleIdentifier: snapshot.applicationBundleIdentifier,
            windowTitle: snapshot.windowTitle,
            fieldRole: snapshot.role,
            selectedText: snapshot.selectedText,
            canReplaceSelection: !snapshot.isTerminal && selectedRangeHasSelection(snapshot.selectedRange),
            canInsertAtCursor: true,
            isTerminal: snapshot.isTerminal
        )
    }

    func applyEdit(
        snapshotID: String,
        operation: FocusedTextEditOperation,
        replacementText: String
    ) async throws -> (presentation: FocusedEditPresentation, toolOutput: String) {
        guard let id = UUID(uuidString: snapshotID), let snapshot = snapshots[id] else {
            throw FocusedTextIntegrationError.snapshotUnavailable
        }
        guard !replacementText.isEmpty else {
            throw FocusedTextIntegrationError.emptyReplacement
        }

        try validate(snapshot, expectedValue: snapshot.originalValue)

        if snapshot.isTerminal {
            guard operation == .insertAtCursor else {
                throw FocusedTextIntegrationError.terminalOnlyStagesCommands
            }
            try await pasteText(replacementText, into: snapshot, expectedValue: nil)
            let presentation = FocusedEditPresentation(
                kind: .terminalCommand,
                applicationName: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                insertedText: replacementText,
                summary: "Staged a command in \(snapshot.applicationName)",
                detail: "Not run. Review it in Terminal, then press Return when you are ready.",
                canUndo: false,
                shouldAutoExpand: true
            )
            return (presentation, Self.successJSON(status: "command_staged", presentation: presentation))
        }

        guard let originalValue = snapshot.originalValue else {
            guard operation != .replaceField else {
                throw FocusedTextIntegrationError.fieldIsNotWritable
            }
            if operation == .replaceSelection, !selectedRangeHasSelection(snapshot.selectedRange) {
                throw FocusedTextIntegrationError.selectionUnavailable
            }
            try await pasteText(replacementText, into: snapshot, expectedValue: nil)
            let presentation = FocusedEditPresentation(
                kind: .textEdit,
                applicationName: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                originalText: originalTextForPresentation(snapshot: snapshot, operation: operation),
                insertedText: replacementText,
                summary: editSummary(for: operation),
                detail: "Pasted into the verified focused field. Review it before sending.",
                canUndo: false,
                shouldAutoExpand: true
            )
            return (presentation, Self.successJSON(status: "focused_text_staged", presentation: presentation))
        }

        let updatedValue = try valueAfterApplying(
            operation: operation,
            replacementText: replacementText,
            originalValue: originalValue,
            selectedRange: snapshot.selectedRange
        )

        let directWriteResult = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        let usedPasteFallback: Bool
        if directWriteResult == .success {
            guard Self.stringAttribute(kAXValueAttribute, from: snapshot.element) == updatedValue else {
                throw FocusedTextIntegrationError.writeCouldNotBeVerified
            }
            usedPasteFallback = false
        } else {
            // Web views and a few cross-platform editors expose selection through
            // Accessibility but reject AXValue writes. Pasting is a safe fallback
            // because the snapshot still proves which field and selection are active.
            try await pasteText(replacementText, into: snapshot, expectedValue: originalValue)
            if let latestValue = Self.stringAttribute(kAXValueAttribute, from: snapshot.element),
               latestValue != updatedValue {
                throw FocusedTextIntegrationError.writeCouldNotBeVerified
            }
            usedPasteFallback = true
        }

        if usedPasteFallback {
            // A field that rejected AXValue writes cannot be restored reliably through
            // the same API, so do not advertise an undo action for a paste fallback.
            undoTransaction = nil
        } else {
            undoTransaction = UndoTransaction(snapshot: snapshot, updatedValue: updatedValue, createdAt: Date())
        }
        let originalExcerpt = originalTextForPresentation(snapshot: snapshot, operation: operation)
        let presentation = FocusedEditPresentation(
            kind: .textEdit,
            applicationName: snapshot.applicationName,
            windowTitle: snapshot.windowTitle,
            originalText: originalExcerpt,
            insertedText: replacementText,
            summary: editSummary(for: operation),
            detail: usedPasteFallback
                ? "Pasted into the verified focused field. Review it before sending."
                : "Updated the verified focused field.",
            canUndo: !usedPasteFallback,
            shouldAutoExpand: true
        )
        return (presentation, Self.successJSON(status: "focused_text_updated", presentation: presentation))
    }

    func undoLastEdit() throws -> FocusedEditPresentation {
        guard let transaction = undoTransaction else {
            throw FocusedTextIntegrationError.noUndoAvailable
        }
        guard Date().timeIntervalSince(transaction.createdAt) <= Self.undoLifetime else {
            undoTransaction = nil
            throw FocusedTextIntegrationError.undoExpired
        }

        try validate(transaction.snapshot, expectedValue: transaction.updatedValue, requiresMatchingSelection: false)
        guard let originalValue = transaction.snapshot.originalValue else {
            throw FocusedTextIntegrationError.noUndoAvailable
        }

        let result = AXUIElementSetAttributeValue(
            transaction.snapshot.element,
            kAXValueAttribute as CFString,
            originalValue as CFTypeRef
        )
        guard result == .success,
              Self.stringAttribute(kAXValueAttribute, from: transaction.snapshot.element) == originalValue else {
            throw FocusedTextIntegrationError.writeCouldNotBeVerified
        }

        undoTransaction = nil
        return FocusedEditPresentation(
            kind: .undo,
            applicationName: transaction.snapshot.applicationName,
            windowTitle: transaction.snapshot.windowTitle,
            summary: "Restored the previous text",
            detail: "The focused field is back to its earlier value.",
            canUndo: false,
            shouldAutoExpand: true
        )
    }

    func safetyPresentation(for error: Error) -> FocusedEditPresentation {
        let applicationName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the focused app"
        return FocusedEditPresentation(
            kind: .safetyNotice,
            applicationName: applicationName,
            summary: "Macky did not type anything",
            detail: error.localizedDescription,
            canUndo: false,
            shouldAutoExpand: true
        )
    }

    private func captureSnapshot() throws -> Snapshot {
        guard AXIsProcessTrusted() else {
            throw FocusedTextIntegrationError.accessibilityPermissionRequired
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw FocusedTextIntegrationError.noExternalFocusedApplication
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = Self.elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement) else {
            throw FocusedTextIntegrationError.noFocusedField
        }

        let role = Self.stringAttribute(kAXRoleAttribute, from: element) ?? "unknown"
        let subrole = Self.stringAttribute(kAXSubroleAttribute, from: element) ?? ""
        guard !isSecureField(role: role, subrole: subrole) else {
            throw FocusedTextIntegrationError.secureField
        }

        let isTerminal = Self.knownTerminalBundleIdentifiers.contains(bundleIdentifier)
        let value = isTerminal ? nil : Self.stringAttribute(kAXValueAttribute, from: element)
        if let value, value.count > Self.maxEditableValueLength {
            throw FocusedTextIntegrationError.fieldIsTooLarge
        }

        let selectedRange = Self.selectedRange(from: element)
        let selectedText = Self.stringAttribute(kAXSelectedTextAttribute, from: element)
            .map { String($0.prefix(Self.maxSelectedTextLength)) }
        let isTextRole = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
        let editable = Self.boolAttribute(kAXEditableAttribute, from: element) ?? isTextRole
        guard editable || isTerminal else {
            throw FocusedTextIntegrationError.fieldIsNotWritable
        }

        return Snapshot(
            id: UUID(),
            applicationName: application.localizedName ?? bundleIdentifier,
            applicationBundleIdentifier: bundleIdentifier,
            applicationProcessIdentifier: application.processIdentifier,
            windowTitle: Self.focusedWindowTitle(from: applicationElement),
            element: element,
            role: role,
            frame: Self.frame(from: element),
            originalValue: value,
            selectedRange: selectedRange,
            selectedText: selectedText,
            isTerminal: isTerminal,
            capturedAt: Date()
        )
    }

    private func validate(
        _ snapshot: Snapshot,
        expectedValue: String?,
        requiresMatchingSelection: Bool = true
    ) throws {
        guard Date().timeIntervalSince(snapshot.capturedAt) <= Self.snapshotLifetime else {
            throw FocusedTextIntegrationError.snapshotExpired
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == snapshot.applicationProcessIdentifier,
              application.bundleIdentifier == snapshot.applicationBundleIdentifier else {
            throw FocusedTextIntegrationError.focusChanged
        }

        let applicationElement = AXUIElementCreateApplication(snapshot.applicationProcessIdentifier)
        guard let currentElement = Self.elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement),
              Self.stringAttribute(kAXRoleAttribute, from: currentElement) == snapshot.role,
              Self.frame(from: currentElement) == snapshot.frame else {
            throw FocusedTextIntegrationError.focusChanged
        }

        if requiresMatchingSelection,
           !selectionStillMatches(snapshot, currentElement: currentElement) {
            throw FocusedTextIntegrationError.fieldChanged
        }

        if let expectedValue,
           Self.stringAttribute(kAXValueAttribute, from: currentElement) != expectedValue {
            throw FocusedTextIntegrationError.fieldChanged
        }
    }

    private func valueAfterApplying(
        operation: FocusedTextEditOperation,
        replacementText: String,
        originalValue: String,
        selectedRange: CFRange?
    ) throws -> String {
        switch operation {
        case .replaceField:
            return replacementText
        case .replaceSelection, .insertAtCursor:
            guard let selectedRange,
                  selectedRange.location != kCFNotFound,
                  selectedRange.location >= 0,
                  selectedRange.length >= 0,
                  let range = Range(NSRange(location: selectedRange.location, length: selectedRange.length), in: originalValue) else {
                throw FocusedTextIntegrationError.selectionUnavailable
            }
            if operation == .replaceSelection, selectedRange.length == 0 {
                throw FocusedTextIntegrationError.selectionUnavailable
            }
            return originalValue.replacingCharacters(in: range, with: replacementText)
        }
    }

    private func selectionStillMatches(_ snapshot: Snapshot, currentElement: AXUIElement) -> Bool {
        guard !snapshot.isTerminal else { return true }
        if let expectedRange = snapshot.selectedRange {
            guard let currentRange = Self.selectedRange(from: currentElement),
                  currentRange.location == expectedRange.location,
                  currentRange.length == expectedRange.length else {
                return false
            }
        }
        if let expectedText = snapshot.selectedText {
            return Self.stringAttribute(kAXSelectedTextAttribute, from: currentElement) == expectedText
        }
        return true
    }

    private func pasteText(_ text: String, into snapshot: Snapshot, expectedValue: String?) async throws {
        try validate(snapshot, expectedValue: expectedValue)
        let pasteboard = NSPasteboard.general
        let originalItems = Self.copyPasteboardItems(pasteboard.pasteboardItems)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw FocusedTextIntegrationError.pasteFailed
        }
        let MackyPasteboardChangeCount = pasteboard.changeCount

        try validate(snapshot, expectedValue: expectedValue)
        try Self.postPasteShortcut()
        try await Task.sleep(for: .milliseconds(150))

        // Restore only if the user or the target app has not placed newer content on
        // the clipboard in the meantime. Never overwrite a user copy action.
        if pasteboard.changeCount == MackyPasteboardChangeCount {
            pasteboard.clearContents()
            if !originalItems.isEmpty {
                _ = pasteboard.writeObjects(originalItems)
            }
        }
    }

    private func originalTextForPresentation(snapshot: Snapshot, operation: FocusedTextEditOperation) -> String? {
        switch operation {
        case .replaceSelection:
            return snapshot.selectedText
        case .insertAtCursor, .replaceField:
            return nil
        }
    }

    private func editSummary(for operation: FocusedTextEditOperation) -> String {
        switch operation {
        case .replaceSelection: return "Replaced the selected text"
        case .insertAtCursor: return "Inserted text at the cursor"
        case .replaceField: return "Replaced the focused field"
        }
    }

    private static func successJSON(status: String, presentation: FocusedEditPresentation) -> String {
        let object: [String: Any] = [
            "status": status,
            "application_name": presentation.applicationName,
            "summary": presentation.summary,
            "detail": presentation.detail,
            "can_undo": presentation.canUndo,
            "execution_performed": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"focused_text_updated\"}"
        }
        return string
    }

    private static func selectedRangeHasSelection(_ range: CFRange?) -> Bool {
        guard let range else { return false }
        return range.location != kCFNotFound && range.length > 0
    }

    private static func isSecureField(role: String, subrole: String) -> Bool {
        role == kAXSecureTextFieldRole as String || subrole.localizedCaseInsensitiveContains("secure")
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? AXUIElement
    }

    private static func selectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value as? AXValue else { return nil }
        var range = CFRange(location: kCFNotFound, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func frame(from element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAXValue = positionValue as? AXValue,
              let sizeAXValue = sizeValue as? AXValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func focusedWindowTitle(from applicationElement: AXUIElement) -> String? {
        guard let window = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement) else { return nil }
        return stringAttribute(kAXTitleAttribute, from: window)
    }

    private static func copyPasteboardItems(_ items: [NSPasteboardItem]?) -> [NSPasteboardItem] {
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

    private static func postPasteShortcut() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw FocusedTextIntegrationError.pasteFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private enum FocusedTextIntegrationError: LocalizedError {
    case accessibilityPermissionRequired
    case noExternalFocusedApplication
    case noFocusedField
    case secureField
    case fieldIsNotWritable
    case fieldIsTooLarge
    case snapshotUnavailable
    case snapshotExpired
    case focusChanged
    case fieldChanged
    case selectionUnavailable
    case emptyReplacement
    case terminalOnlyStagesCommands
    case writeCouldNotBeVerified
    case pasteFailed
    case noUndoAvailable
    case undoExpired

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Focused text editing needs Accessibility permission."
        case .noExternalFocusedApplication:
            return "Focus an app outside Macky, then try again."
        case .noFocusedField:
            return "Focus a text field or terminal prompt, then try again."
        case .secureField:
            return "Macky does not read or write secure text fields."
        case .fieldIsNotWritable:
            return "The focused control is not a writable text field."
        case .fieldIsTooLarge:
            return "The focused text is too large to edit safely. Select the part you want changed instead."
        case .snapshotUnavailable:
            return "The focused field needs to be checked again before Macky can edit it."
        case .snapshotExpired:
            return "The focused field check expired. Keep the field focused and try again."
        case .focusChanged:
            return "Focus changed, so Macky did not type anything."
        case .fieldChanged:
            return "The text changed after Macky inspected it, so nothing was overwritten."
        case .selectionUnavailable:
            return "Select the text you want Macky to replace first."
        case .emptyReplacement:
            return "Macky needs text to insert."
        case .terminalOnlyStagesCommands:
            return "Terminal commands can only be staged at the cursor; Macky will not replace Terminal output."
        case .writeCouldNotBeVerified:
            return "Macky could not verify the text update, so it was not reported as complete."
        case .pasteFailed:
            return "Macky could not paste into the focused field."
        case .noUndoAvailable:
            return "There is no focused-text edit available to undo."
        case .undoExpired:
            return "The focused-text undo window has expired."
        }
    }
}
