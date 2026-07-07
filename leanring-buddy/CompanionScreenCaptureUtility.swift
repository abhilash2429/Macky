//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayID: CGDirectDisplayID
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int

    var visualGuidanceDisplayFrame: VisualGuidanceDisplayFrame {
        VisualGuidanceDisplayFrame(
            x: Double(displayFrame.origin.x),
            y: Double(displayFrame.origin.y),
            width: Double(displayFrame.width),
            height: Double(displayFrame.height),
            displayID: displayID
        )
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures connected displays as JPEG data, labeling each with whether the user's
    /// cursor is on that screen.
    ///
    /// `cursorScreenOnly` captures the display the user is actively pointing at, which is
    /// the default screen-context path. `mainScreenOnly` remains available for rare callers
    /// that explicitly need the primary display. Pass both flags as false only when the
    /// request is genuinely about more than one screen. On a single-display Mac all paths
    /// are identical.
    static func captureAllScreensAsJPEG(cursorScreenOnly: Bool = true, mainScreenOnly: Bool = false) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let allSortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        let sortedDisplays: [SCDisplay]
        if mainScreenOnly,
           let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let mainDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) {
            sortedDisplays = [mainDisplay]
        } else {
            // Fast path: capture only the cursor display (the first after sorting) unless
            // all screens were explicitly requested. Skips the capture + JPEG encode of
            // every other monitor, which is the common single-screen-question case.
            sortedDisplays = cursorScreenOnly ? Array(allSortedDisplays.prefix(1)) : allSortedDisplays
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the notch panel's screen frame.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            // Capture at the display's logical point dimensions, not a fixed 1280 cap.
            // SCStreamConfiguration.width/height are in POINTS; ScreenCaptureKit scales the
            // output image to exactly those point dimensions. On Retina the native capture
            // is physical (2x), but setting the config to logical points yields a JPEG whose
            // pixel dimensions equal the display's logical point space. That makes overlay and
            // cursor coordinates map 1:1 to the screen with no further scaling. (This is
            // numerically the same as dividing physical pixels by backingScaleFactor, but this
            // is the correct mechanism — do NOT multiply by any scale factor.)
            configuration.width = Int(displayFrame.width)
            configuration.height = Int(displayFrame.height)

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = isCursorScreen ? "user's screen (cursor is here)" : "user's main screen"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayID: display.displayID,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
