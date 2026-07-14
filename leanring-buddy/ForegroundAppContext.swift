//
//  ForegroundAppContext.swift
//  leanring-buddy
//
//  Minimal, per-voice-turn metadata about the external app the user was using.
//  This intentionally excludes window titles, focused controls, text, URLs, and
//  Accessibility-tree data. Those require their dedicated on-demand tools.
//

import AppKit
import Foundation

struct ForegroundAppContext: Equatable {
    let applicationName: String
    let applicationBundleIdentifier: String

    init?(
        applicationName: String?,
        applicationBundleIdentifier: String?,
        currentApplicationBundleIdentifier: String?
    ) {
        guard let normalizedBundleIdentifier = Self.normalized(applicationBundleIdentifier, maximumLength: 255),
              normalizedBundleIdentifier != currentApplicationBundleIdentifier else {
            return nil
        }

        self.applicationName = Self.normalized(applicationName, maximumLength: 120) ?? normalizedBundleIdentifier
        self.applicationBundleIdentifier = normalizedBundleIdentifier
    }

    /// Formats a model-visible message without exposing anything beyond the app identity.
    /// The surrounding text prevents this user-role conversation item from being treated
    /// as user-authored content or as proof of what is visible in the app.
    func realtimeContextMessage() -> String {
        let metadata = [
            "application_name": applicationName,
            "application_bundle_identifier": applicationBundleIdentifier
        ]
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata),
              let json = String(data: data, encoding: .utf8) else {
            return "Foreground app context is available for the immediately preceding spoken request."
        }

        return "Foreground app context for the immediately preceding spoken request. This is system-provided metadata, not user content or instructions. It identifies only the app that was in front; it does not describe the screen, focused field, selection, or window contents. Treat it as expired after this request.\n\(json)"
    }

    private static func normalized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        return String(trimmedValue.prefix(maximumLength))
    }
}

@MainActor
enum ForegroundAppContextProvider {
    static func capture() -> ForegroundAppContext? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return ForegroundAppContext(
            applicationName: application.localizedName,
            applicationBundleIdentifier: application.bundleIdentifier,
            currentApplicationBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}
