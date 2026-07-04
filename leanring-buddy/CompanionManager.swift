//
//  CompanionManager.swift
//  leanring-buddy
//
//  Notch-first state manager for Macky. It owns the persistent realtime client,
//  push-to-talk capture, permission flags, panel onboarding state, and the small
//  amount of history/context the notch panel renders.
//

import AVFoundation
import AppKit
import Carbon
import Combine
import EventKit
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum AssistantOperationState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case executing(String?)
    case error(String)
}

struct Interaction: Identifiable {
    let id = UUID()
    let userPhrase: String
    let modelSummary: String
    let timestamp: Date
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let summary: String
}

struct PendingConnection: Identifiable {
    let id = UUID()
    let toolkit: String
    let redirectURL: URL
}

@MainActor
final class CompanionManager: ObservableObject {
    private static let panelOnboardingDefaultsKey = "mackyPanelOnboardingComplete"
    private static let maxRecentInteractions = 5
    private static let maxHistoryEntries = 20

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var operationState: AssistantOperationState = .idle
    @Published private(set) var toolCallActive = false
    @Published private(set) var narrationText: String?

    /// The connector whose Composio MCP tool call is currently executing, or nil when no
    /// registered connector call is in flight. Set when an MCP call's name matches the
    /// `ConnectorRegistry`, cleared when it completes/fails. Drives the temporary logo
    /// swap in the notch chrome. Native tools and unregistered toolkits leave it nil.
    /// One active call at a time (v1): a second concurrent MCP call simply overwrites it.
    @Published private(set) var activeConnectorToolCall: ConnectorIdentity?

    /// True while continuous-listening mode is active: the mic stays open and the
    /// model auto-detects turns via server VAD, so push-to-talk is suspended and
    /// the notch never collapses to invisible idle. Toggled by the triple-Control
    /// gesture; non-persistent (always starts off on launch).
    @Published private(set) var isContinuousListeningActive = false

    @Published private(set) var recentInteractions: [Interaction] = []
    @Published private(set) var historyLog: [HistoryEntry] = []
    @Published var pendingFileContext: [String] = []
    @Published var pendingImageContext: [Data] = []
    @Published var pendingDroppedFiles: [URL] = []
    @Published private(set) var pendingAttachmentNames: [String] = []
    @Published private(set) var pendingConnections: [PendingConnection] = []
    /// Lowercased toolkit slugs the user has a live (ACTIVE) connection to. Drives
    /// the "connected" tick in the connectors grid. Refreshed from the worker.
    @Published private(set) var connectedToolkits: Set<String> = []

    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasCalendarPermission = false
    @Published private(set) var hasRemindersPermission = false
    /// Apple Events / Automation permission to control Spotify and Music. Powers the
    /// notch panel's now-playing card. Optional — it is intentionally NOT part of
    /// `allPermissionsGranted`, so a user who never controls music isn't blocked.
    @Published private(set) var hasAutomationPermission = false
    @Published private(set) var isRequestingScreenContent = false
    /// Bumped right before each native (TCC) permission prompt is triggered. The
    /// panel controller observes it and temporarily drops the notch window level so
    /// the system permission dialog isn't hidden behind the panel.
    @Published private(set) var systemPromptToken = 0
    @Published var hasCompletedPanelOnboarding: Bool = UserDefaults.standard.bool(forKey: CompanionManager.panelOnboardingDefaultsKey)

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let realtimeClient = RealtimeClient()
    let visualGuidanceOverlayController = VisualGuidanceOverlayController()
    let subAgentProgressController = SubAgentProgressController()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var controlTriplePressCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var realtimeActivityCancellables = Set<AnyCancellable>()
    private var accessibilityCheckTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?

    /// Half-duplex tail for continuous mode: after the model finishes speaking we
    /// hold off re-forwarding mic audio this long, so the speaker's acoustic tail
    /// can't echo back into server VAD and re-trigger a turn. See `micResumeAfterUptime`.
    private static let continuousMicResumeCooldown: TimeInterval = 0.25
    /// Earliest `systemUptime` at which continuous mode may resume forwarding mic
    /// audio. Pushed forward while playback is active; `0` means no hold.
    private var micResumeAfterUptime: TimeInterval = 0

    /// Watchdog for continuous mode: if a turn never completes (e.g. a tool call or
    /// response that stalls, or a dropped connection), we'd otherwise sit frozen in a
    /// non-listening state forever. If we stay non-listening with nothing actually
    /// playing for this long, snap back to listening so the notch un-sticks and the
    /// next utterance can proceed. Generous enough not to cut off a legitimately slow
    /// tool call.
    private static let continuousStuckTimeout: TimeInterval = 15
    /// `systemUptime` when continuous mode last entered a non-listening state with no
    /// audio playing; `0` while listening or actively speaking. Drives the watchdog.
    private var continuousStuckSince: TimeInterval = 0
    private var lastNarration: String?
    private var turnUsedTool = false
    private var activeToolCount = 0
    private var pendingVisualGuidanceSequence: VisualGuidanceSequence?

    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
            && hasCalendarPermission
            && hasRemindersPermission
    }

    var isAssistantActive: Bool {
        // Continuous-listening mode keeps the notch live even between turns so it
        // never collapses to fully invisible idle while the mic is open.
        isContinuousListeningActive || voiceState != .idle || toolCallActive || operationState != .idle
    }

    var activeStatusText: String {
        switch operationState {
        case .idle:
            return ""
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .executing(let label):
            return label ?? narrationText ?? "Executing"
        case .error:
            return "Needs attention"
        }
    }

    var hasCompletedOnboarding: Bool {
        get { hasCompletedPanelOnboarding }
        set { setPanelOnboardingComplete(newValue) }
    }

    func start() {
        refreshAllPermissions()
        startPermissionPolling()
        observeAppActivation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindRealtimeClient()
        realtimeClient.connect()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        realtimeClient.disconnect()
        pendingKeyboardShortcutStartTask?.cancel()
        shortcutTransitionCancellable?.cancel()
        controlTriplePressCancellable?.cancel()
        audioPowerCancellable?.cancel()
        realtimeActivityCancellables.removeAll()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
    }

    func setPanelOnboardingComplete(_ isComplete: Bool = true) {
        hasCompletedPanelOnboarding = isComplete
        UserDefaults.standard.set(isComplete, forKey: Self.panelOnboardingDefaultsKey)
    }

    func attachDroppedText(_ text: String, name: String) {
        guard !text.isEmpty else { return }
        pendingFileContext.append("Attached file \"\(name)\":\n\(text)")
        pendingAttachmentNames.append(name)
    }

    func enqueueDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingDroppedFiles.append(contentsOf: urls)
    }

    func attachDroppedImage(_ data: Data, name: String) {
        guard !data.isEmpty else { return }
        pendingImageContext.append(data)
        pendingAttachmentNames.append(name)
    }

    func clearPendingAttachments() {
        pendingFileContext = []
        pendingImageContext = []
        pendingAttachmentNames = []
    }

    func openPendingConnection(_ connection: PendingConnection) {
        // Connector-connect funnel step 2: the user opened the connect link in the browser.
        MackyAnalytics.connectorConnect(step: .linkOpened, toolkit: connection.toolkit)
        NSWorkspace.shared.open(connection.redirectURL)
    }

    func dismissPendingConnection(_ connection: PendingConnection) {
        pendingConnections.removeAll { $0.id == connection.id }
    }

    /// The Cloudflare Worker endpoint that returns a Composio connect link directly,
    /// bypassing the realtime voice model so a connector tap doesn't trigger filler.
    /// Host derives from the shared `WorkerEndpoints`.
    private static let composioConnectURL = WorkerEndpoints.composioConnectURL
    /// Worker endpoint listing the user's live (ACTIVE) connections.
    private static let composioConnectionsURL = WorkerEndpoints.composioConnectionsURL

    /// Refreshes the set of live connections from the worker so the connectors grid
    /// can show a "connected" tick. Also clears any stale pending link for a toolkit
    /// that is now actually connected.
    func refreshConnectedToolkits() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.composioConnectionsURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let slugs = json["connected"] as? [String] else { return }
                let connected = Set(slugs.map { $0.lowercased() })
                // Connector-connect funnel step 3: toolkits that just became connected
                // since the last refresh (a confirmed connection completing the funnel).
                let newlyConnected = connected.subtracting(self.connectedToolkits)
                for toolkit in newlyConnected {
                    MackyAnalytics.connectorConnect(step: .connectionConfirmed, toolkit: toolkit)
                }
                self.connectedToolkits = connected
                self.pendingConnections.removeAll { connected.contains($0.toolkit.lowercased()) }
            } catch {
                print("⚠️ Companion: refreshConnectedToolkits failed: \(error)")
            }
        }
    }

    func requestConnectorConnection(slug: String) {
        let normalizedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSlug.isEmpty else { return }
        operationState = .executing("connecting \(normalizedSlug)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Self.fetchConnectLink(slug: normalizedSlug)
                let connection = PendingConnection(toolkit: normalizedSlug, redirectURL: url)
                self.pendingConnections.removeAll { $0.toolkit.caseInsensitiveCompare(normalizedSlug) == .orderedSame }
                self.pendingConnections.append(connection)
                self.openPendingConnection(connection)
                if self.operationState == .executing("connecting \(normalizedSlug)") {
                    self.operationState = .idle
                }
            } catch {
                print("⚠️ Companion: connector connect failed for \(normalizedSlug): \(error)")
                if self.operationState == .executing("connecting \(normalizedSlug)") {
                    self.operationState = .idle
                }
            }
        }
    }

    /// Calls the worker's `/composio-connect` endpoint and returns the redirect URL.
    private static func fetchConnectLink(slug: String) async throws -> URL {
        var request = URLRequest(url: composioConnectURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["toolkit": slug])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlString = json["redirect_url"] as? String,
            let url = URL(string: urlString)
        else {
            throw URLError(.cannotParseResponse)
        }
        return url
    }

    func submitPanelContext(texts: [String], images: [Data]) {
        guard !texts.isEmpty || !images.isEmpty else { return }
        voiceState = .processing
        operationState = .thinking
        realtimeClient.sendUserContext(texts: texts, images: images)
        realtimeClient.requestResponse()
    }

    func refreshAllPermissions() {
        hasAccessibilityPermission = WindowPositionManager.hasAccessibilityPermission()
        if hasAccessibilityPermission {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        // CGPreflightScreenCaptureAccess() (inside hasScreenRecordingPermission())
        // opens an XPC connection to the screen-capture daemon on every call, which
        // logs "XPC connection was invalidated" repeatedly when polled on a timer.
        // Probe only until it reports granted; after that the value is sticky for the
        // process, and a revoke-while-running is re-detected on the next activation.
        if !hasScreenRecordingPermission {
            hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
        }

        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        hasRemindersPermission = remindersStatus == .fullAccess || remindersStatus == .writeOnly

        // Automation is optional and Apple Events permission checks can stall launch on
        // fresh Macs. Only trust the cached grant here; explicit Settings → Automation
        // requests perform the live check/prompt off the main thread.
        hasAutomationPermission = UserDefaults.standard.bool(forKey: "hasAutomationPermission")

        // Once the two out-of-band permissions (granted in System Settings) are in,
        // there's nothing left for the timer to catch — stop polling.
        if hasAccessibilityPermission && hasScreenRecordingPermission {
            accessibilityCheckTimer?.invalidate()
            accessibilityCheckTimer = nil
        }
    }

    /// Signals the panel controller to drop the notch window level so the incoming
    /// native permission dialog renders above the panel instead of behind it.
    private func signalSystemPrompt() {
        systemPromptToken &+= 1
    }

    func requestMicrophonePermission() {
        signalSystemPrompt()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.hasMicrophonePermission = granted
                    self?.refreshAllPermissions()
                }
            }
        default:
            openPrivacySettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func requestScreenRecordingPermission() {
        signalSystemPrompt()
        _ = WindowPositionManager.requestScreenRecordingPermission()
        refreshAllPermissions()
    }

    func requestAccessibilityPermission() {
        signalSystemPrompt()
        _ = WindowPositionManager.requestAccessibilityPermission()
        refreshAllPermissions()
    }

    func requestCalendarPermission() {
        signalSystemPrompt()
        Task {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
            refreshAllPermissions()
        }
    }

    func requestRemindersPermission() {
        signalSystemPrompt()
        Task {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToReminders()
            refreshAllPermissions()
        }
    }

    /// Triggers the macOS Automation prompt for the music players. If a player is
    /// running and the decision is undetermined, this surfaces the "Macky wants to
    /// control Spotify" dialog. If it's already denied (or no player is running, so the
    /// system can't prompt), we fall back to opening the Automation settings pane so the
    /// user can flip the toggle by hand.
    func requestAutomationPermission() {
        signalSystemPrompt()
        let players = ["com.spotify.client", "com.apple.Music"]
        let running = players.filter { bundleID in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        }
        // The AE call blocks while the dialog is up, so keep it off the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            for bundleID in running {
                _ = await Self.requestAutomation(forBundleIdentifier: bundleID)
            }
            await MainActor.run {
                guard let self else { return }
                self.refreshAllPermissions()
                // Couldn't get a grant via the prompt (denied, or nothing running to
                // prompt against): send the user straight to the right settings pane.
                if !self.hasAutomationPermission {
                    self.openPrivacySettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                }
            }
        }
    }

    /// Reads — without prompting — whether this app may send Apple events to `bundleID`.
    /// Returns true only on an explicit authorization (`noErr`); a not-yet-decided
    /// state, a denial, or the target not running all read as not granted.
    private static func isAutomationAuthorized(forBundleIdentifier bundleID: String) -> Bool {
        automationStatus(forBundleIdentifier: bundleID, askUserIfNeeded: false) == noErr
    }

    /// Asks macOS for Automation permission for `bundleID`, surfacing the system prompt
    /// when the decision is undetermined and the target is running. Returns the status.
    @discardableResult
    private static func requestAutomation(forBundleIdentifier bundleID: String) -> OSStatus {
        automationStatus(forBundleIdentifier: bundleID, askUserIfNeeded: true)
    }

    private static func automationStatus(forBundleIdentifier bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        guard let data = bundleID.data(using: .utf8) else { return OSStatus(-1) }
        var target = AEAddressDesc()
        let createStatus = data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &target)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUserIfNeeded)
    }

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        signalSystemPrompt()
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    isRequestingScreenContent = false
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                isRequestingScreenContent = false
                guard didCapture else { return }
                hasScreenContentPermission = true
                UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                isRequestingScreenContent = false
            }
        }
    }

    /// Timestamp of the most recent push-to-talk release, used to measure turn latency
    /// (release → first response-audio byte). Nil once measured for the current turn.
    private var turnReleaseTimestamp: Date?

    private func bindRealtimeClient() {
        subAgentProgressController.onCancel = { [weak self] in
            self?.visualGuidanceOverlayController.clear()
        }
        visualGuidanceOverlayController.onSequenceCompleted = { [weak self] in
            self?.subAgentProgressController.hide()
        }

        realtimeClient.onVisualGuidanceSequenceRequested = { [weak self] sequence in
            guard let self else { return "{\"error\": \"app unavailable\"}" }
            self.pendingVisualGuidanceSequence = sequence
            self.subAgentProgressController.show(currentStep: "Building visual guide")
            self.subAgentProgressController.markCompleted("Built visual guide", next: "Waiting for narration")
            return "{\"status\": \"visual guidance queued for narration\"}"
        }

        realtimeClient.onVisualGuidanceClearRequested = { [weak self] in
            guard let self else { return "{\"error\": \"app unavailable\"}" }
            self.pendingVisualGuidanceSequence = nil
            self.visualGuidanceOverlayController.clear()
            self.subAgentProgressController.hide()
            return "{\"status\": \"cleared\"}"
        }

        realtimeClient.onCursorMoveRequested = { command, space in
            do {
                return try await CursorGuidanceIntegration.move(to: command, coordinateSpace: space)
            } catch {
                return "{\"error\": \"\(Self.escapeForJSON(error.localizedDescription))\"}"
            }
        }

        realtimeClient.onCursorClickRequested = { command, space in
            do {
                return try await CursorGuidanceIntegration.click(at: command, coordinateSpace: space)
            } catch {
                return "{\"error\": \"\(Self.escapeForJSON(error.localizedDescription))\"}"
            }
        }

        realtimeClient.onResponseAudioStarted = { [weak self] in
            guard let self else { return }
            // Turn latency: time from push-to-talk release to the first response-audio
            // byte — the user-perceived "how fast did it answer". Measured once per turn.
            if let start = self.turnReleaseTimestamp {
                MackyAnalytics.turnLatency(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
                self.turnReleaseTimestamp = nil
            }
            self.voiceState = .responding
            self.operationState = .speaking
            self.startPendingVisualGuidanceIfNeeded()
        }

        realtimeClient.onResponseCompleted = { [weak self] in
            guard let self else { return }
            // Barge-in guard: pressing push-to-talk mid-response cancels the old
            // response, whose late `response.done` arrives after we've already moved
            // to `.listening` for the new turn. Ignore it so the notch stays live
            // on "Listening" instead of flickering back to idle.
            if self.voiceState == .listening { return }
            // Note: no `toolCallActive` guard here. `RealtimeClient.settleIfIdle()`
            // only invokes this once nothing is in flight (incl. tools/MCP), so an
            // in-flight tool can't reach this path — and the old guard raced the
            // async `$isToolActive` sink, stranding the notch on "Executing".
            // Continuous mode never goes idle between turns: settle back to
            // "Listening" so the mic-open state stays visible in the notch. (The
            // half-duplex tail is handled by the mic gate, keyed on real playback.)
            if self.isContinuousListeningActive {
                self.voiceState = .listening
                self.operationState = .listening
                return
            }
            self.voiceState = .idle
            self.operationState = .idle
        }

        realtimeClient.onSpeechStarted = { [weak self] in
            guard let self, self.isContinuousListeningActive else { return }
            self.voiceState = .listening
            self.operationState = .listening
            self.turnUsedTool = false
        }

        realtimeClient.onSpeechStopped = { [weak self] in
            guard let self, self.isContinuousListeningActive else { return }
            self.voiceState = .processing
            self.operationState = .thinking
        }

        realtimeClient.onToolCallStarted = { [weak self] toolName in
            self?.beginToolActivity(toolName: toolName)
        }

        realtimeClient.onToolCallEnded = { [weak self] in
            self?.endToolActivity()
        }

        realtimeClient.onMCPCallStarted = { [weak self] toolName in
            guard let self else { return }
            self.beginToolActivity(toolName: toolName)
            // Swap the notch's branding logo to this connector for the call's duration.
            // nil when the tool isn't a registered connector (or is the meta tool), which
            // leaves the default logo in place.
            self.activeConnectorToolCall = ConnectorRegistry.match(toolName: toolName)
        }

        realtimeClient.onMCPCallEnded = { [weak self] in
            guard let self else { return }
            self.endToolActivity()
            self.activeConnectorToolCall = nil
        }

        realtimeClient.onConnectionLinkAvailable = { [weak self] toolkit, url in
            guard let self else { return }
            self.pendingConnections.removeAll { $0.toolkit.caseInsensitiveCompare(toolkit) == .orderedSame }
            self.pendingConnections.append(PendingConnection(toolkit: toolkit, redirectURL: url))
        }

        realtimeClient.onTurnCompleted = { [weak self] userPhrase, modelText in
            guard let self else { return }
            self.recordInteraction(userPhrase: userPhrase, modelText: modelText)
            if !self.turnUsedTool {
                self.appendHistory(Self.firstSentence(of: modelText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        realtimeClient.$currentActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in self?.handleActivityChange(activity) }
            .store(in: &realtimeActivityCancellables)

        realtimeClient.$isToolActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                if active {
                    self.turnUsedTool = true
                    self.toolCallActive = true
                    self.operationState = .executing(self.narrationText)
                } else if self.activeToolCount == 0 {
                    self.toolCallActive = false
                }
            }
            .store(in: &realtimeActivityCancellables)
    }

    private func startPendingVisualGuidanceIfNeeded() {
        guard let sequence = pendingVisualGuidanceSequence else { return }
        pendingVisualGuidanceSequence = nil
        visualGuidanceOverlayController.run(sequence: sequence)
        subAgentProgressController.markCompleted("Narration started", next: "Showing overlay")
    }

    private func beginToolActivity(toolName: String) {
        activeToolCount += 1
        turnUsedTool = true
        // Model-sourced narration wins. By the time onToolCallStarted fires,
        // RealtimeClient has already published `currentActivity` (the model's spoken
        // narration for this call), which `handleActivityChange` copied into
        // `narrationText`. Only fall back to the hardcoded `narrationPhrase` table when
        // the model didn't narrate this call (e.g. a fast/instant tool the prompt tells
        // it to run silently), so the executing state still shows *something* rather
        // than overwriting a real model phrase with a generic guess.
        let label = narrationText ?? Self.narrationPhrase(for: toolName)
        narrationText = label
        toolCallActive = true
        operationState = .executing(label)
    }

    private func endToolActivity() {
        activeToolCount = max(0, activeToolCount - 1)
        guard activeToolCount == 0 else { return }
        toolCallActive = false
        narrationText = nil
        // Safety net: if a connector's MCP-ended event was missed, clearing here on the
        // last tool's completion keeps the swapped logo from being stranded.
        activeConnectorToolCall = nil
        if voiceState == .responding {
            operationState = .speaking
        } else if voiceState == .processing {
            operationState = .thinking
        } else if isContinuousListeningActive {
            // Continuous mode never goes idle between turns — stay on "Listening".
            operationState = .listening
            voiceState = .listening
        } else {
            operationState = .idle
            voiceState = .idle
        }
    }

    private func startPermissionPolling() {
        // Only needed while a System-Settings permission is still missing; the timer
        // self-invalidates from refreshAllPermissions() once both are granted.
        guard !(hasAccessibilityPermission && hasScreenRecordingPermission) else { return }
        guard accessibilityCheckTimer == nil else { return }
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Re-checks permissions when the app regains focus — the moment the user
    /// returns after toggling a permission in System Settings — and resumes polling
    /// if something was revoked. Replaces a perpetual timer for the steady state.
    private func observeAppActivation() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshAllPermissions()
                self.startPermissionPolling()
                // The user may have just finished an OAuth flow in the browser;
                // re-check live connections so the connector tick updates.
                self.refreshConnectedToolkits()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        controlTriplePressCancellable = globalPushToTalkShortcutMonitor
            .controlTriplePressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.toggleContinuousListening()
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        // Push-to-talk is suspended while continuous-listening mode is active so the
        // two modes never run at once.
        guard !isContinuousListeningActive else { return }
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            realtimeClient.interruptPlayback()
            realtimeClient.clearAudioBuffer()
            voiceState = .listening
            operationState = .listening
            turnUsedTool = false
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.buddyDictationManager.startRealtimeAudioStreaming { [weak self] pcm16Chunk in
                        DispatchQueue.main.async {
                            self?.realtimeClient.sendAudio(pcm16Chunk)
                        }
                    }
                } catch {
                    print("⚠️ Companion: couldn't start realtime audio streaming: \(error)")
                    self.buddyDictationManager.stopRealtimeAudioStreaming()
                    self.voiceState = .idle
                    self.operationState = .error(error.localizedDescription)
                }
            }
        case .released:
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            if buddyDictationManager.stopRealtimeAudioStreaming() {
                voiceState = .processing
                operationState = .thinking
                turnReleaseTimestamp = Date()
                guard realtimeClient.commitAudio() else {
                    voiceState = .idle
                    operationState = .idle
                    return
                }
                if !pendingFileContext.isEmpty || !pendingImageContext.isEmpty {
                    realtimeClient.sendUserContext(texts: pendingFileContext, images: pendingImageContext)
                    clearPendingAttachments()
                }
                if !pendingDroppedFiles.isEmpty {
                    realtimeClient.sendDroppedFiles(pendingDroppedFiles)
                    pendingDroppedFiles = []
                }
                realtimeClient.requestResponse()
            } else if !toolCallActive {
                voiceState = .idle
                operationState = .idle
            }
        case .none:
            break
        }
    }

    /// Toggles continuous-listening mode (triple-Control gesture). On: suspend
    /// push-to-talk, enable server VAD, and hold the mic open so the model handles
    /// turns hands-free while the notch stays on "Listening". Off: close the mic,
    /// restore manual push-to-talk, and let the notch return to invisible idle.
    func toggleContinuousListening() {
        if isContinuousListeningActive {
            // Turn off → back to push-to-talk.
            isContinuousListeningActive = false
            buddyDictationManager.stopRealtimeAudioStreaming()
            realtimeClient.setContinuousTurnDetection(false)
            realtimeClient.interruptPlayback()
            voiceState = .idle
            operationState = .idle
            return
        }

        // Turn on → continuous listening. Clear any in-flight push-to-talk capture
        // first so the mic isn't double-started (startRealtimeAudioStreaming no-ops
        // if a handler is already installed).
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        buddyDictationManager.stopRealtimeAudioStreaming()
        realtimeClient.interruptPlayback()
        realtimeClient.clearAudioBuffer()

        micResumeAfterUptime = 0
        continuousStuckSince = 0
        isContinuousListeningActive = true
        realtimeClient.setContinuousTurnDetection(true)
        voiceState = .listening
        operationState = .listening
        turnUsedTool = false

        pendingKeyboardShortcutStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.buddyDictationManager.startRealtimeAudioStreaming { [weak self] pcm16Chunk in
                    DispatchQueue.main.async {
                        self?.forwardContinuousMicChunk(pcm16Chunk)
                    }
                }
            } catch {
                print("⚠️ Companion: couldn't start continuous audio streaming: \(error)")
                self.isContinuousListeningActive = false
                self.realtimeClient.setContinuousTurnDetection(false)
                self.buddyDictationManager.stopRealtimeAudioStreaming()
                self.voiceState = .idle
                self.operationState = .error(error.localizedDescription)
            }
        }
    }

    /// Forwards one continuous-mode mic chunk, applying half-duplex echo gating and
    /// the stuck-turn watchdog. Runs on the main actor (mic tap → main dispatch).
    private func forwardContinuousMicChunk(_ pcm16Chunk: Data) {
        guard isContinuousListeningActive else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // Half-duplex echo gate: while the speakers are emitting the model's reply
        // (and for a short acoustic tail after), don't forward mic audio — otherwise
        // the open mic feeds the model's own voice back into server VAD, which treats
        // the echo as a new turn, interrupts the reply, and stutters playback. Keyed
        // on real playback (self-clearing), never on UI state, so a stalled turn can
        // never leave the mic muted.
        if realtimeClient.isPlayingResponseAudio {
            micResumeAfterUptime = now + Self.continuousMicResumeCooldown
            continuousStuckSince = 0
            return
        }
        if now < micResumeAfterUptime { return }

        // Stuck-turn watchdog: nothing is playing. If we've been parked in a
        // non-listening state for too long — a tool call or response that never
        // completed, or a dropped connection — snap back to listening so the notch
        // recovers and the next utterance can proceed.
        if voiceState != .listening {
            if continuousStuckSince == 0 {
                continuousStuckSince = now
            } else if now - continuousStuckSince > Self.continuousStuckTimeout {
                recoverContinuousListening()
            }
        } else {
            continuousStuckSince = 0
        }

        realtimeClient.sendAudio(pcm16Chunk)
    }

    /// Clears a stalled continuous-mode turn back to a clean listening state so the
    /// notch un-sticks and the session is ready for the next utterance.
    private func recoverContinuousListening() {
        print("⚠️ Companion: continuous-mode turn stalled, recovering to listening")
        continuousStuckSince = 0
        activeToolCount = 0
        toolCallActive = false
        narrationText = nil
        turnUsedTool = false
        voiceState = .listening
        operationState = .listening
    }

    private func recordInteraction(userPhrase: String, modelText: String) {
        let trimmedUser = userPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty || !trimmedModel.isEmpty else { return }

        recentInteractions.insert(
            Interaction(userPhrase: trimmedUser, modelSummary: Self.firstSentence(of: trimmedModel), timestamp: Date()),
            at: 0
        )
        if recentInteractions.count > Self.maxRecentInteractions {
            recentInteractions.removeLast(recentInteractions.count - Self.maxRecentInteractions)
        }
    }

    private func appendHistory(_ summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        historyLog.append(HistoryEntry(timestamp: Date(), summary: trimmed))
        if historyLog.count > Self.maxHistoryEntries {
            historyLog.removeFirst(historyLog.count - Self.maxHistoryEntries)
        }
    }

    private func handleActivityChange(_ activity: String?) {
        guard let activity else { return }
        if activity.hasPrefix("✓") {
            let summary = lastNarration.map { "\($0) \(activity)" } ?? activity
            appendHistory(summary)
            lastNarration = nil
        } else {
            lastNarration = activity
            narrationText = activity
            operationState = .executing(activity)
        }
    }

    private static func firstSentence(of text: String) -> String {
        guard let end = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else {
            return text
        }
        return String(text[...end])
    }

    private static func escapeForJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// FALLBACK ONLY — not the primary narration source. The product contract
    /// (MACKY.md) is that the *words come from the model*: RealtimeClient publishes the
    /// model's spoken narration as `currentActivity`, which is what normally fills the
    /// notch's executing label. This hardcoded table is consulted only by
    /// `beginToolActivity` when the model did not narrate a given call (a fast/instant
    /// tool it was told to run silently), so the executing state isn't left blank. It is
    /// deliberately approximate — do not treat it as authoritative or re-promote it to
    /// the primary mechanism. Connector (MCP) calls never reach it; their phrase comes
    /// from `RealtimeClient.connectorActivityPhrase`.
    private static func narrationPhrase(for toolName: String) -> String? {
        let normalized = toolName.lowercased()
        if normalized.contains("screen") { return "looking at your screen" }
        if normalized.contains("calendar") || normalized.contains("slot") { return "checking your calendar" }
        if normalized.contains("reminder") { return "updating reminders" }
        if normalized.contains("volume") { return "adjusting volume" }
        if normalized.contains("music") { return "controlling music" }
        if normalized.contains("chrome") || normalized.contains("url") { return "opening browser" }
        if normalized.contains("open_app") { return "opening app" }
        if normalized.contains("lock") { return "locking screen" }
        if normalized.contains("disturb") { return "toggling Do Not Disturb" }
        return "working"
    }

    private func openPrivacySettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
