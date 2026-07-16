//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Macky's app entry point. Launches the persistent realtime pipeline and hosts
//  the product UI exclusively in the notch panel.
//

import AppKit
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(MackyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MackyAppDelegate: NSObject, NSApplicationDelegate {
    private var companionManager: CompanionManager?
    private var notchPanelController: NotchPanelController?
    private var isPreparingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Product analytics starts before any other session state so early events are captured.
        MackyAnalytics.start()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        let manager = CompanionManager()
        companionManager = manager
        let draftingProvider = AgentSkillDraftingProvider()
        SkillsWindowController.shared.configure(
            companionManager: manager,
            draftingProvider: draftingProvider
        )
        notchPanelController = NotchPanelController(companionManager: manager)
        manager.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let companionManager else { return .terminateNow }
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        Task { @MainActor in
            await companionManager.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AuthManager.shared.handleIncomingURL(url)
        }
    }

    @objc
    private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        AuthManager.shared.handleIncomingURL(url)
    }
}
