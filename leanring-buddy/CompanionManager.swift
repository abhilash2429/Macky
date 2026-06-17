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
    case awaitingApproval(String?)
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
    @Published private(set) var isRequestingScreenContent = false
    /// Bumped right before each native (TCC) permission prompt is triggered. The
    /// panel controller observes it and temporarily drops the notch window level so
    /// the system permission dialog isn't hidden behind the panel.
    @Published private(set) var systemPromptToken = 0
    @Published var hasCompletedPanelOnboarding: Bool = UserDefaults.standard.bool(forKey: CompanionManager.panelOnboardingDefaultsKey)

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let realtimeClient = RealtimeClient()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var realtimeActivityCancellables = Set<AnyCancellable>()
    private var accessibilityCheckTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var lastNarration: String?
    private var turnUsedTool = false
    private var activeToolCount = 0

    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
            && hasCalendarPermission
            && hasRemindersPermission
    }

    var isAssistantActive: Bool {
        voiceState != .idle || toolCallActive || operationState != .idle
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
        case .awaitingApproval(let label):
            return label ?? "Awaiting approval"
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
        NSWorkspace.shared.open(connection.redirectURL)
    }

    func dismissPendingConnection(_ connection: PendingConnection) {
        pendingConnections.removeAll { $0.id == connection.id }
    }

    /// The Cloudflare Worker endpoint that returns a Composio connect link directly,
    /// bypassing the realtime voice model so a connector tap doesn't trigger filler.
    private static let composioConnectURL = URL(string: "https://realtime-proxy.speedmac.workers.dev/composio-connect")!
    /// Worker endpoint listing the user's live (ACTIVE) connections.
    private static let composioConnectionsURL = URL(string: "https://realtime-proxy.speedmac.workers.dev/composio-connections")!

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

    func clearDetectedElementLocation() {}

    private func bindRealtimeClient() {
        realtimeClient.onResponseAudioStarted = { [weak self] in
            guard let self else { return }
            self.voiceState = .responding
            self.operationState = .speaking
        }

        realtimeClient.onResponseCompleted = { [weak self] in
            guard let self else { return }
            // Barge-in guard: pressing push-to-talk mid-response cancels the old
            // response, whose late `response.done` arrives after we've already moved
            // to `.listening` for the new turn. Ignore it so the notch stays live
            // on "Listening" instead of flickering back to idle.
            if self.voiceState == .listening { return }
            if self.toolCallActive {
                self.operationState = .executing(self.narrationText)
                return
            }
            self.voiceState = .idle
            self.operationState = .idle
        }

        realtimeClient.onToolCallStarted = { [weak self] toolName in
            self?.beginToolActivity(toolName: toolName)
        }

        realtimeClient.onToolCallEnded = { [weak self] in
            self?.endToolActivity()
        }

        realtimeClient.onMCPCallStarted = { [weak self] toolName in
            self?.beginToolActivity(toolName: toolName)
        }

        realtimeClient.onMCPCallEnded = { [weak self] in
            self?.endToolActivity()
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

    private func beginToolActivity(toolName: String) {
        activeToolCount += 1
        turnUsedTool = true
        let label = Self.narrationPhrase(for: toolName)
        narrationText = label
        toolCallActive = true
        operationState = .executing(label)
    }

    private func endToolActivity() {
        activeToolCount = max(0, activeToolCount - 1)
        guard activeToolCount == 0 else { return }
        toolCallActive = false
        narrationText = nil
        if voiceState == .responding {
            operationState = .speaking
        } else if voiceState == .processing {
            operationState = .thinking
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
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
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
                realtimeClient.commitAudio()
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

    private static func narrationPhrase(for toolName: String) -> String? {
        let normalized = toolName.lowercased()
        if normalized.contains("screen") { return "looking at your screen" }
        if normalized.contains("calendar") { return "checking your calendar" }
        if normalized.contains("reminder") { return "updating reminders" }
        if normalized.contains("volume") { return "adjusting volume" }
        if normalized.contains("chrome") || normalized.contains("url") { return "opening browser" }
        if normalized.contains("mcp") || normalized.contains("composio") { return "using connector" }
        return "executing"
    }

    private func openPrivacySettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
