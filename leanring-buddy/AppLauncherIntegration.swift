//
//  AppLauncherIntegration.swift
//  leanring-buddy
//
//  The open_app function tool: launches or activates any installed macOS app by
//  name. RealtimeClient registers a thin handler that awaits openApp(named:),
//  mirroring how the system-control tools delegate to SystemControlsIntegration.
//
//  App lookup scans the standard .app bundle locations and matches the model's
//  spoken name — exact case-insensitive first, then a loose substring match in
//  either direction — so "Reminders", "open Safari", and "Visual Studio Code"
//  all resolve to a real bundle.
//

import AppKit
import Foundation

enum AppLauncherIntegration {

    /// The directories macOS apps normally live in. Scanned in this order, so a
    /// bundle in /Applications wins over one with the same name in the system or
    /// user locations.
    private static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// Finds an installed app matching `name` and launches or activates it.
    /// Returns `{"status": "opened", "app": "<resolved name>"}` on success and
    /// `{"error": "app not found: <name>"}` when nothing matches, so the model
    /// can say it couldn't find the app out loud instead of going silent.
    static func openApp(named name: String) async throws -> String {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard the empty case explicitly: Swift's String.contains("") is true,
        // so an empty query would otherwise "match" the first installed app.
        guard !query.isEmpty, let match = resolveApp(named: query) else {
            return "{\"error\": \"app not found: \(escapeForJSON(query))\"}"
        }

        // Activate the app if it's already running rather than spawning a second
        // instance, matching the "switch to it" intent of "open Reminders".
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // The completion-handler API is bridged to async per AGENTS rule 9; the
        // native async overload exists but we keep the explicit continuation to
        // mirror the rest of the codebase's bridging style.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: match.url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return "{\"status\": \"opened\", \"app\": \"\(escapeForJSON(match.name))\"}"
    }

    /// A spoken app name resolved to a real installed bundle.
    private struct ResolvedApp {
        /// The display name without the ".app" extension, e.g. "Visual Studio Code".
        let name: String
        let url: URL
    }

    /// Resolves `query` to an installed .app bundle. An exact case-insensitive
    /// name match wins first; failing that, falls back to a case-insensitive
    /// substring match in either direction (the query inside an app's name, or an
    /// app's name inside the query) so "code" finds "Visual Studio Code" and
    /// "open the reminders app" still finds "Reminders".
    private static func resolveApp(named query: String) -> ResolvedApp? {
        let apps = installedApps()

        if let exact = apps.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact
        }

        let loweredQuery = query.lowercased()
        return apps.first { app in
            let loweredName = app.name.lowercased()
            return loweredName.contains(loweredQuery) || loweredQuery.contains(loweredName)
        }
    }

    /// Cached app list + the time it was built. Without this, every `open_app` voice
    /// command re-walked four directories with `FileManager.contentsOfDirectory`,
    /// adding filesystem latency to a hot voice path. The set of installed apps
    /// changes rarely, so a short TTL is plenty: a freshly-installed app is resolvable
    /// within `cacheTTL` seconds, and the common case (resolving an already-installed
    /// app) skips the scan entirely.
    private static var cachedApps: [ResolvedApp]?
    private static var cacheTimestamp: Date = .distantPast
    private static let cacheTTL: TimeInterval = 60

    /// Lists every .app bundle across the search directories, preserving the
    /// directory order so earlier locations win when names collide. Cached for
    /// `cacheTTL` seconds to avoid a full filesystem rescan on every voice command.
    private static func installedApps() -> [ResolvedApp] {
        if let cachedApps, Date().timeIntervalSince(cacheTimestamp) < cacheTTL {
            return cachedApps
        }

        let fileManager = FileManager.default
        var apps: [ResolvedApp] = []

        for directory in searchDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue  // directory may not exist (e.g. ~/Applications) — skip it
            }

            for entry in entries where entry.pathExtension == "app" {
                let name = entry.deletingPathExtension().lastPathComponent
                apps.append(ResolvedApp(name: name, url: entry))
            }
        }

        cachedApps = apps
        cacheTimestamp = Date()
        return apps
    }

    /// Escapes the two characters that would break a hand-built JSON string.
    /// App names rarely contain quotes or backslashes, but guarding keeps the
    /// returned result valid JSON for the model to parse.
    private static func escapeForJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
