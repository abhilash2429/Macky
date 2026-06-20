//
//  SystemControlsIntegration.swift
//  leanring-buddy
//
//  Milestone 8: the five system function tools the model can call —
//  volume up/down, Do Not Disturb toggle, lock screen, open a URL in Chrome,
//  and open a new Chrome tab. These are the first "action" integrations and
//  need no OAuth/EventKit permissions, just Accessibility (for the keystroke
//  tools, already granted for push-to-talk) and one-time Automation consent
//  (for controlling Chrome via Apple Events).
//
//  The action methods are stateless statics; RealtimeClient registers thin
//  function-tool handlers that await them, mirroring how get_screen_context
//  delegates to CompanionScreenCaptureUtility.
//

import AppKit
import Foundation

enum SystemControlsIntegration {

    // MARK: - Volume
    //
    // Volume is driven by simulating the keyboard's volume media keys rather
    // than AppleScript's `set volume`. AppleScript changes the level silently —
    // it never shows macOS's on-screen volume bezel. Simulating the media keys
    // both changes the volume (in the system's native 1/16 notches) AND makes
    // the native bezel appear, so the user gets visual confirmation. This needs
    // Accessibility permission, already granted for the push-to-talk key tap.

    /// macOS adjusts the system volume in 16 discrete notches (each ≈ 6.25%).
    private static let volumeNotchCount = 16
    private static let soundUpKeyCode = 0   // NX_KEYTYPE_SOUND_UP
    private static let soundDownKeyCode = 1 // NX_KEYTYPE_SOUND_DOWN

    /// Raises the volume. With `level` (e.g. "turn it up to 80 percent") it moves
    /// to the notch nearest that percentage; otherwise it nudges up one notch.
    static func volumeUp(level: Int?) async throws -> String {
        if let level {
            return try await setVolume(toPercent: level)
        }
        await tapVolumeKey(up: true)
        return "{\"status\": \"volume raised\"}"
    }

    /// Lowers the volume. With `level` (e.g. "turn it down to 50 percent") it moves
    /// to the notch nearest that percentage; otherwise it nudges down one notch.
    static func volumeDown(level: Int?) async throws -> String {
        if let level {
            return try await setVolume(toPercent: level)
        }
        await tapVolumeKey(up: false)
        return "{\"status\": \"volume lowered\"}"
    }

    /// Moves the volume to the notch nearest `percent` (0–100) by tapping the
    /// volume media keys the right number of times, so the native bezel animates
    /// to the target. Targets snap to the nearest 1/16 notch.
    private static func setVolume(toPercent percent: Int) async throws -> String {
        let clampedPercent = max(0, min(100, percent))
        let targetNotch = notch(forPercent: clampedPercent)
        let currentNotch = try await currentVolumeNotch()
        let delta = targetNotch - currentNotch

        if delta == 0 {
            // Already at the target notch — tap once and back so the bezel still
            // shows, netting zero. Step away from whichever boundary we're against.
            let firstTapUp = targetNotch < volumeNotchCount
            await tapVolumeKey(up: firstTapUp)
            await tapVolumeKey(up: !firstTapUp)
        } else {
            let movingUp = delta > 0
            for _ in 0..<abs(delta) {
                await tapVolumeKey(up: movingUp)
                try? await Task.sleep(nanoseconds: 25_000_000) // let each bezel step register
            }
        }

        let resultingPercent = targetNotch * 100 / volumeNotchCount
        return "{\"status\": \"volume set to \(resultingPercent)\"}"
    }

    /// Reads the current output volume (0–100) and converts it to the nearest notch.
    private static func currentVolumeNotch() async throws -> Int {
        let output = try await runAppleScript("output volume of (get volume settings)")
        let percent = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return notch(forPercent: percent)
    }

    private static func notch(forPercent percent: Int) -> Int {
        Int((Double(percent) / 100.0 * Double(volumeNotchCount)).rounded())
    }

    /// Posts a volume up/down media-key down+up pair, which changes the volume by
    /// one notch and triggers the native macOS volume bezel.
    @MainActor
    private static func tapVolumeKey(up: Bool) {
        let keyCode = up ? soundUpKeyCode : soundDownKeyCode
        postSystemDefinedKey(keyCode, keyDown: true)
        postSystemDefinedKey(keyCode, keyDown: false)
    }

    /// Builds and posts an NSSystemDefined aux-key event — the standard recipe
    /// for simulating the hardware media keys. The magic flag values (0xa = down,
    /// 0xb = up) are the documented encoding for these special-key events.
    @MainActor
    private static func postSystemDefinedKey(_ keyCode: Int, keyDown: Bool) {
        let data1 = (keyCode << 16) | ((keyDown ? 0xa : 0xb) << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: keyDown ? 0xa00 : 0xb00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Do Not Disturb

    /// Toggles Do Not Disturb by sending the ⌃⌥⌘Z keystroke through System
    /// Events. macOS 14 removed the old `System Events … do not disturb`
    /// AppleScript property, so there's no way to set DND state directly. This
    /// keystroke only takes effect if the user has bound it to "Do Not Disturb"
    /// in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control;
    /// otherwise it's a harmless no-op. We therefore report that the keystroke
    /// was *sent*, not that DND definitely changed.
    static func toggleDoNotDisturb() async throws -> String {
        try await runAppleScript(
            "tell application \"System Events\" to keystroke \"z\" using {command down, option down, control down}"
        )
        return "{\"status\": \"sent do not disturb toggle shortcut\"}"
    }

    // MARK: - Lock Screen

    /// Locks the screen via the ⌘⌃Q keystroke (the macOS default Lock Screen
    /// shortcut) through System Events.
    static func lockScreen() async throws -> String {
        try await runAppleScript(
            "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"
        )
        return "{\"status\": \"screen locked\"}"
    }

    // MARK: - Chrome

    /// Opens `urlString` in Google Chrome. A scheme-less domain (e.g.
    /// "github.com") is normalized to https://. Returns an error JSON for an
    /// unparseable URL or when Chrome can't be launched (e.g. not installed).
    @MainActor
    static func openURLInChrome(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "{\"error\": \"empty url\"}"
        }
        // Prepend https:// when the model passes a bare domain with no scheme.
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else {
            return "{\"error\": \"invalid url\"}"
        }

        // Deprecated since 10.15 but still functional, and the explicitly chosen
        // API for this milestone. Returns false if Chrome couldn't be launched.
        let opened = NSWorkspace.shared.open(
            [url],
            withAppBundleIdentifier: "com.google.Chrome",
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        guard opened else {
            return "{\"error\": \"could not open Chrome\"}"
        }
        return "{\"status\": \"opened in Chrome\"}"
    }

    /// Opens a new tab in Google Chrome. Requires one-time Automation (Apple
    /// Events) consent on first use.
    static func newChromeTab() async throws -> String {
        try await runAppleScript(
            "tell application \"Google Chrome\" to open location \"about:newtab\""
        )
        return "{\"status\": \"opened new Chrome tab\"}"
    }

    // MARK: - Media playback (Spotify / Apple Music)
    //
    // Transport controls for the already-open desktop player, driven locally over
    // Apple events instead of a Composio connector round-trip — so pause / resume /
    // skip are near-instant instead of a multi-second cloud hop. Starting a *specific*
    // track by name still needs the Spotify connector (it has to search first); this
    // only drives whatever is already loaded in the player. Requires the one-time
    // Automation consent (the same grant the now-playing card uses).

    /// Players we control, Spotify first (the common case), then Apple Music.
    private static let mediaPlayers: [(bundleID: String, appName: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music"),
    ]

    /// The running player to target, or nil when neither Spotify nor Music is open
    /// (in which case there's nothing local to control and the caller should fall
    /// back to the connector).
    private static func activeMediaPlayer() -> (bundleID: String, appName: String)? {
        let running = NSWorkspace.shared.runningApplications
        return mediaPlayers.first { player in
            running.contains { $0.bundleIdentifier == player.bundleID }
        }
    }

    /// Runs a transport command against the active player. `action` is one of
    /// play (resume), pause, next, previous, now_playing — plus a few tolerated
    /// synonyms. Returns `{"status": …}` (consumed by the notch confirmation) or
    /// `{"error": …}` when no player is open.
    static func controlMusic(action: String) async throws -> String {
        guard let player = activeMediaPlayer() else {
            return "{\"error\": \"no music app is open\"}"
        }
        let app = player.appName

        switch action.lowercased() {
        case "pause":
            try await runAppleScript("tell application \"\(app)\" to pause")
            return "{\"status\": \"paused\"}"
        case "play", "resume":
            try await runAppleScript("tell application \"\(app)\" to play")
            return "{\"status\": \"playing\"}"
        case "playpause", "toggle":
            try await runAppleScript("tell application \"\(app)\" to playpause")
            return "{\"status\": \"toggled playback\"}"
        case "next", "skip":
            try await runAppleScript("tell application \"\(app)\" to next track")
            return "{\"status\": \"skipped to next track\"}"
        case "previous", "back":
            try await runAppleScript("tell application \"\(app)\" to previous track")
            return "{\"status\": \"back to previous track\"}"
        case "now_playing", "current":
            return try await nowPlaying(app: app)
        default:
            return "{\"error\": \"unknown action\"}"
        }
    }

    /// Reads the current track + play state from `app`. Tolerates no current track
    /// (ad / podcast boundary) and serializes via JSONSerialization so track/artist
    /// text can't break the JSON.
    private static func nowPlaying(app: String) async throws -> String {
        let script = """
        tell application "\(app)"
            set _state to player state as string
            set _name to ""
            set _artist to ""
            try
                set _name to name of current track
                set _artist to artist of current track
            end try
            return _state & "\t" & _name & "\t" & _artist
        end tell
        """
        let raw = try await runAppleScript(script)
        let fields = raw.components(separatedBy: "\t")
        let state = fields.first ?? "unknown"
        let name = fields.count > 1 ? fields[1] : ""
        let artist = fields.count > 2 ? fields[2] : ""

        var payload: [String: Any] = ["status": state, "player": app]
        if !name.isEmpty { payload["track"] = name }
        if !artist.isEmpty { payload["artist"] = artist }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"status\": \"\(state)\"}"
        }
        return json
    }

    // MARK: - AppleScript execution

    /// Runs `source` through `/usr/bin/osascript` in a child process on a
    /// background thread, so the (blocking) wait never stalls the main thread —
    /// the safe alternative to NSAppleScript, which is main-thread-only.
    /// Throws with the script's stderr text on a non-zero exit.
    @discardableResult
    private static func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Detached so Process.waitUntilExit() runs off the calling (main) actor.
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let reason = message.isEmpty ? "osascript exited with status \(process.terminationStatus)" : message
                    continuation.resume(throwing: SystemControlsError.scriptFailed(reason))
                    return
                }

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}

enum SystemControlsError: LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let reason):
            return reason
        }
    }
}
