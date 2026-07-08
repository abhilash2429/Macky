//
//  SkillsWindowController.swift
//  leanring-buddy
//
//  Standalone window that hosts the Skills catalog (browse + enable/disable). Ports
//  the window-management mechanism from boring.notch's SettingsWindowController.swift
//  (activation-policy dance, singleton NSWindowController, NSWindowDelegate close
//  handling) \u2014 not its visual content, which lives in SkillsWindowView.swift.
//
//  CompanionManager is not a singleton (unlike boring.notch's BoringViewCoordinator/
//  MusicManager), so this controller can't build its SwiftUI content until the app
//  hands one over via `configure(companionManager:)`, mirroring how boring.notch's
//  controller defers its content view until `setUpdaterController(_:)` is called.
//

import AppKit
import SwiftUI

@MainActor
final class SkillsWindowController: NSWindowController {
    static let shared = SkillsWindowController()

    private var companionManager: CompanionManager?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hands the controller its `CompanionManager` reference so it can build the
    /// SwiftUI content view. Call once at app launch.
    func configure(companionManager: CompanionManager) {
        self.companionManager = companionManager
        setupWindow()
    }

    private func setupWindow() {
        guard let window = window else { return }

        window.title = "Macky Skills"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true

        // Make it behave like a regular app window with proper Spaces support.
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]

        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false

        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("MackySkillsWindow")

        if let companionManager {
            let skillsView = SkillsWindowView(companionManager: companionManager)
            window.contentView = NSHostingView(rootView: skillsView)
        }

        window.delegate = self
    }

    func showWindow() {
        guard companionManager != nil else {
            assertionFailure("SkillsWindowController.showWindow() called before configure(companionManager:)")
            return
        }

        // Set app to regular mode first.
        NSApp.setActivationPolicy(.regular)

        // If window is already visible, bring it to front properly.
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }

        // Show the window with proper ordering.
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.center()

        // Activate the app and ensure window gets focus.
        NSApp.activate(ignoringOtherApps: true)

        // Force window to front after activation.
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    override func close() {
        super.close()
        relinquishFocus()
    }

    private func relinquishFocus() {
        window?.orderOut(nil)

        // Set app back to accessory mode immediately.
        NSApp.setActivationPolicy(.accessory)
    }
}

extension SkillsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func windowDidResignKey(_ notification: Notification) {
    }
}
