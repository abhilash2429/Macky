//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Notch-panel-only companion app. No dock icon, no main window, no menu bar
//  status item — the companion lives entirely in the floating notch panel
//  managed by NotchPanelController, which observes the voice pipeline.
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the notch panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    /// Owns the notch panel for the app's lifetime, independent of the voice
    /// pipeline. Created on launch and never torn down.
    private var notchPanelController: NotchPanelController?

    /// The first-launch sign-in window, shown only while there's no Keychain session.
    private var authWindow: NSWindow?
    private var authPhaseCancellable: AnyCancellable?

    /// The first-run onboarding flow, shown once after first auth until the user
    /// completes it (tracked under UserDefaults "onboardingCompleted").
    private var onboardingManager: OnboardingManager?

    /// Registers the custom URL-scheme handler before launch finishes. The Apple
    /// Event (kAEGetURL) handler is the reliable path for LSUIElement apps;
    /// `application(_:open:)` below is a belt-and-suspenders fallback. Both route
    /// into AuthManager, which ignores duplicate deliveries.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AuthManager.shared.handleIncomingURL(url)
        }
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent: NSAppleEventDescriptor
    ) {
        guard let urlString = event
            .paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
            .stringValue,
            let url = URL(string: urlString) else {
            return
        }
        AuthManager.shared.handleIncomingURL(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Enforce a single live instance before any setup. Clicky auto-launches as
        // a login item, so on a Cmd+R from Xcode a second copy would otherwise run
        // alongside the already-running one — two WebSockets, two voices, two
        // overlays. The newest instance wins: terminate any older ones first.
        terminateOtherInstances()

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // Create the notch panel up front. It observes companionManager's
        // voiceState (read-only) to drive expand/collapse.
        notchPanelController = NotchPanelController(companionManager: companionManager)

        companionManager.start()

        // Gate the app behind magic-link auth. With a stored Keychain session we
        // jump straight into the normal launch UI; otherwise we show the sign-in
        // window and defer the panel until auth completes.
        if AuthManager.shared.hasSession {
            presentPostAuthUIIfNeeded()
        } else {
            showAuthWindow()
        }

        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    /// Drives the post-auth UI. On first run (before "onboardingCompleted") this
    /// shows the dedicated onboarding flow. Once that's done — or on every launch
    /// thereafter — there's nothing more to present here: the notch panel surfaces
    /// any remaining work (permissions, intro) on its own.
    private func presentPostAuthUIIfNeeded() {
        if !OnboardingManager.isComplete {
            let manager = OnboardingManager(companionManager: companionManager)
            manager.onFinished = { [weak self] in
                self?.onboardingManager = nil
                self?.presentPostAuthUIIfNeeded()
            }
            onboardingManager = manager
            manager.show()
            return
        }
    }

    /// Shows the centered sign-in window and watches for authentication. Once the
    /// user verifies their magic link, the window closes and the normal launch UI
    /// takes over.
    private func showAuthWindow() {
        authPhaseCancellable = AuthManager.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, phase == .authenticated else { return }
                self.dismissAuthWindow()
                self.presentPostAuthUIIfNeeded()
            }

        let hostingController = NSHostingController(
            rootView: AuthView(authManager: AuthManager.shared)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Sign in to Speed"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        authWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func dismissAuthWindow() {
        authPhaseCancellable?.cancel()
        authPhaseCancellable = nil
        authWindow?.close()
        authWindow = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Terminates any other running copies of this app (same bundle identifier,
    /// different process) so only this — the most recently launched — instance
    /// stays alive. Uses a graceful `terminate()` so the old copy runs its
    /// `applicationWillTerminate` and cleanly disconnects its WebSocket.
    private func terminateOtherInstances() {
        let myBundleID = Bundle.main.bundleIdentifier
        let myPID = NSRunningApplication.current.processIdentifier
        let duplicates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == myBundleID && $0.processIdentifier != myPID
        }
        for instance in duplicates {
            print("🎯 Clicky: terminating older instance (pid \(instance.processIdentifier))")
            instance.terminate()
        }
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
