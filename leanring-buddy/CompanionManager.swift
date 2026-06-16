//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import AppKit
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// One completed voice turn, shown in the drop panel's history list.
struct Interaction: Identifiable {
    let id = UUID()
    let userPhrase: String     // what the user said (input transcript)
    let modelSummary: String   // first sentence of the model's reply
    let timestamp: Date
}

/// A single line in the activity history log (Session E's history panel). One per
/// completed interaction — a tool-call cycle ("opening slack ✓ opened") or a plain
/// conversational turn (the model's first sentence).
struct HistoryEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let summary: String
}

/// A toolkit the user hasn't connected yet, surfaced as a "Connect <App>" row in
/// the notch panel after the model's COMPOSIO_MANAGE_CONNECTIONS call returned an
/// OAuth Connect Link. Tapping the row opens `redirectURL` in the default browser.
struct PendingConnection: Identifiable {
    let id = UUID()
    let toolkit: String
    let redirectURL: URL
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    /// True while a model-requested tool call is executing. Drives the notch
    /// bar's brief vertical pulse. Set from RealtimeClient's tool callbacks.
    @Published private(set) var toolCallActive: Bool = false
    /// Short narration shown in the notch bar's left zone while a tool call runs
    /// (e.g. "looking at your screen"), overriding the plain state text. Cleared
    /// when the tool call resolves.
    @Published private(set) var narrationText: String? = nil

    /// The text shown in the closed notch bar. A running tool call's narration
    /// wins; otherwise it reflects the voice state. Empty when idle. Single source
    /// of truth shared by AurenStatusBar (display) and NotchPanelController (which
    /// sizes the host window to fit it).
    var activeStatusText: String {
        if toolCallActive, let narration = narrationText {
            return narration
        }
        switch voiceState {
        case .idle:       return ""
        case .listening:  return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking…"
        }
    }

    // MARK: - Drop Panel State (history + queued file context)

    /// Last 5 completed voice turns, newest first. Shown in the drop panel.
    @Published private(set) var recentInteractions: [Interaction] = []

    /// Rolling activity history (last 20) for the history panel. Appended one
    /// entry per completed interaction; see appendHistory / handleActivityChange.
    @Published private(set) var historyLog: [HistoryEntry] = []
    /// Text extracted from dropped files, queued for the next voice turn.
    @Published var pendingFileContext: [String] = []
    /// Raw image data from dropped images (PNG), queued for the next voice turn.
    @Published var pendingImageContext: [Data] = []

    /// File URLs dropped onto the notch's drop zone, queued for attachment on the
    /// next voice turn. RealtimeClient reads each one and attaches it by type
    /// (image / readable text / filename fallback); the queue is cleared after.
    @Published var pendingDroppedFiles: [URL] = []
    /// Filenames of currently queued attachments, shown as confirmation chips.
    @Published private(set) var pendingAttachmentNames: [String] = []

    /// Toolkits awaiting OAuth, shown as "Connect <App>" rows in the notch panel.
    /// Populated when RealtimeClient surfaces a Composio Connect Link; deduped by
    /// toolkit so repeated asks don't stack duplicate rows.
    @Published private(set) var pendingConnections: [PendingConnection] = []

    // MARK: - Panel Display State

    /// Single source of truth for what the open notch panel is showing. The panel
    /// observes this; transitions to `.modelOutput` / `.fileDrop` auto-open it.
    @Published var panelDisplayState: PanelDisplayState = .idle

    /// The live onboarding state machine while the `.onboarding` surface is showing,
    /// so AurenPanel can reach it to render OnboardingView. Nil once onboarding is
    /// complete (or never started).
    @Published private(set) var onboardingManager: OnboardingManager?

    /// Watches AuthManager for the magic-link verification that ends the gate.
    private var authPhaseCancellable: AnyCancellable?
    /// Mirrors the onboarding manager's current step into `panelDisplayState`.
    private var onboardingStepCancellable: AnyCancellable?
    /// Holds the transient post-onboarding welcome before settling to idle.
    private var welcomeTask: Task<Void, Never>?

    /// Minimal now-playing model. The idle panel renders a music chip only while
    /// this is non-nil; no producer wires it yet (voice handles playback), so the
    /// section stays hidden for now.
    struct NowPlayingState: Equatable {
        var title: String
        var artist: String
        var artworkData: Data?
    }
    @Published var nowPlaying: NowPlayingState? = nil

    /// Pushes model-generated content into the panel for the user to review. Sets
    /// `panelDisplayState`; NotchContainerView observes it and opens the panel.
    func pushModelOutput(content: String, type: PanelOutputType) {
        panelDisplayState = .modelOutput(content: content, type: type)
    }

    /// Approve: execute the pending model output. For now this just logs and
    /// returns to idle — per-type send/insert logic is wired in a later session.
    func executePendingModelOutput() {
        if case let .modelOutput(content, type) = panelDisplayState {
            print("✅ CompanionManager: approved model output (\(type)) — \(content.prefix(80))")
        }
        panelDisplayState = .idle
    }

    /// Discard the pending model output and return to the idle dashboard.
    func discardModelOutput() {
        panelDisplayState = .idle
    }

    /// Enters (or extends) the file-drop surface. Merges new URLs into any files
    /// already collected this session, deduped, and flips the panel to `.fileDrop`.
    func beginFileDrop(_ urls: [URL]) {
        var files: [URL] = { if case let .fileDrop(existing) = panelDisplayState { return existing } else { return [] } }()
        for url in urls where !files.contains(url) { files.append(url) }
        panelDisplayState = .fileDrop(files: files)
    }

    /// Replaces the current file-drop list (used by per-file remove). No-op if the
    /// panel isn't currently showing the drop surface.
    func setDroppedFiles(_ urls: [URL]) {
        guard case .fileDrop = panelDisplayState else { return }
        panelDisplayState = .fileDrop(files: urls)
    }

    /// Confirm: queue the collected files for the next voice turn and return to
    /// idle. RealtimeClient.sendDroppedFiles extracts them on the next shortcut release.
    func confirmDroppedFiles(_ urls: [URL]) {
        enqueueDroppedFiles(urls)
        panelDisplayState = .idle
    }

    // MARK: - Launch gate (auth + onboarding)

    /// Decides what the panel shows on launch: the sign-in gate when there's no
    /// Keychain session, the onboarding flow on first run, otherwise the idle
    /// dashboard. Replaces the old standalone auth window / onboarding panel.
    func resolveInitialPanelState() {
        if !AuthManager.shared.hasSession {
            beginAuthGate()
        } else if !OnboardingManager.isComplete {
            beginOnboarding()
        } else {
            panelDisplayState = .idle
        }
    }

    /// Shows the auth surface and watches for the magic-link verification. Once the
    /// user authenticates, proceeds to onboarding (first run) or the idle dashboard.
    private func beginAuthGate() {
        authPhaseCancellable = AuthManager.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, phase == .authenticated else { return }
                self.authPhaseCancellable = nil
                self.proceedAfterAuth()
            }
        panelDisplayState = .auth
    }

    private func proceedAfterAuth() {
        if OnboardingManager.isComplete {
            panelDisplayState = .idle
        } else {
            beginOnboarding()
        }
    }

    /// Spins up the onboarding state machine and drives the panel from it. Each step
    /// change is mirrored into `panelDisplayState` so the panel re-measures; finishing
    /// runs the brief welcome before settling to idle.
    private func beginOnboarding() {
        let manager = OnboardingManager(companionManager: self)
        manager.onFinished = { [weak self] in
            self?.completeOnboarding()
        }
        onboardingStepCancellable = manager.$currentStep
            .receive(on: DispatchQueue.main)
            .sink { [weak self] step in
                self?.panelDisplayState = .onboarding(step: step)
            }
        onboardingManager = manager
        panelDisplayState = .onboarding(step: manager.currentStep)
    }

    /// Holds the onboarding "You're all set" screen briefly as a welcome, then
    /// settles into the idle dashboard and tears down the onboarding machine.
    private func completeOnboarding() {
        welcomeTask?.cancel()
        welcomeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.onboardingStepCancellable = nil
            self.onboardingManager = nil
            self.panelDisplayState = .idle
        }
    }

    /// Most interactions to keep in the history list.
    private static let maxRecentInteractions = 5
    private static let maxHistoryEntries = 20

    /// Queues a dropped text file's contents for the next voice interaction.
    func attachDroppedText(_ text: String, name: String) {
        guard !text.isEmpty else { return }
        pendingFileContext.append("Attached file \"\(name)\":\n\(text)")
        pendingAttachmentNames.append(name)
    }

    /// Queues file URLs dropped on the notch drop zone for the next voice turn.
    func enqueueDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingDroppedFiles.append(contentsOf: urls)
    }

    /// Queues a dropped image (PNG data) for the next voice interaction.
    func attachDroppedImage(_ data: Data, name: String) {
        guard !data.isEmpty else { return }
        pendingImageContext.append(data)
        pendingAttachmentNames.append(name)
    }

    /// Opens a pending connection's OAuth Connect Link in the default browser.
    func openPendingConnection(_ connection: PendingConnection) {
        NSWorkspace.shared.open(connection.redirectURL)
    }

    /// Removes a pending connection row (manual dismiss via the "x" button).
    func dismissPendingConnection(_ connection: PendingConnection) {
        pendingConnections.removeAll { $0.id == connection.id }
    }

    /// Clears all queued attachments (after they're injected into a turn).
    private func clearPendingAttachments() {
        pendingFileContext = []
        pendingImageContext = []
        pendingAttachmentNames = []
    }

    /// Builds a history entry from a completed turn's transcripts and keeps the
    /// list capped at the 5 most recent. Skips empty turns.
    private func recordInteraction(userPhrase: String, modelText: String) {
        let trimmedUser = userPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty || !trimmedModel.isEmpty else { return }

        let interaction = Interaction(
            userPhrase: trimmedUser,
            modelSummary: Self.firstSentence(of: trimmedModel),
            timestamp: Date()
        )
        recentInteractions.insert(interaction, at: 0)
        if recentInteractions.count > Self.maxRecentInteractions {
            recentInteractions.removeLast(recentInteractions.count - Self.maxRecentInteractions)
        }
    }

    /// Appends one entry to the activity history log, capped at the last 20
    /// (oldest dropped). Entries are kept in chronological order (newest last).
    private func appendHistory(_ summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        historyLog.append(HistoryEntry(timestamp: Date(), summary: trimmed))
        if historyLog.count > Self.maxHistoryEntries {
            historyLog.removeFirst(historyLog.count - Self.maxHistoryEntries)
        }
    }

    /// Tracks the model's tool narration so a finished tool cycle can be logged as
    /// "<narration> ✓ <result>". `currentActivity` transitions from the narration
    /// phrase to a "✓ …" confirmation when the tool's result is sent; the "✓"
    /// transition is the cue to write the history entry.
    private func handleActivityChange(_ activity: String?) {
        guard let activity else { return }
        if activity.hasPrefix("✓") {
            let summary = lastNarration.map { "\($0) \(activity)" } ?? activity
            appendHistory(summary)
            lastNarration = nil
        } else {
            lastNarration = activity
        }
    }

    /// Returns the first sentence of `text` (up to the first ., !, or ?), so the
    /// history row stays short.
    private static func firstSentence(of text: String) -> String {
        guard let end = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else {
            return text
        }
        return String(text[...end])
    }
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()

    /// Persistent GPT-Realtime-2 WebSocket (proxied through the Cloudflare
    /// Worker). Opens on launch and stays connected for the whole session.
    let realtimeClient = RealtimeClient()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private var shortcutTransitionCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    /// Subscriptions to RealtimeClient's tool-activity publishers (Session D).
    private var realtimeActivityCancellables = Set<AnyCancellable>()
    /// The narration phrase currently shown for an in-flight tool, used to build
    /// the "<narration> ✓ <result>" history entry when the tool completes.
    private var lastNarration: String?
    /// Whether the current user turn invoked a tool. Reset when listening starts;
    /// used so a tool turn logs only its tool-cycle entry (not a duplicate plain
    /// conversational entry).
    private var turnUsedTool = false
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            isOverlayVisible = true
        } else {
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // The model's voice playback drives the second half of the voiceState
        // cycle: .responding when its audio starts, .idle when it's done.
        realtimeClient.onResponseAudioStarted = { [weak self] in
            self?.voiceState = .responding
        }
        realtimeClient.onResponseCompleted = { [weak self] in
            guard let self else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
        // Tool-call activity pulses the notch bar and shows a narration label.
        realtimeClient.onToolCallStarted = { [weak self] toolName in
            self?.toolCallActive = true
            self?.narrationText = CompanionManager.narrationPhrase(for: toolName)
        }
        realtimeClient.onToolCallEnded = { [weak self] in
            self?.toolCallActive = false
            self?.narrationText = nil
        }
        // The model called present_for_review with a draft: open the panel onto
        // the review card. The raw type string maps to a PanelOutputType.
        realtimeClient.onPresentForReview = { [weak self] content, type in
            guard let self else { return }
            let mapped: PanelOutputType
            switch type {
            case "email_draft":   mapped = .emailDraft
            case "message_draft": mapped = .messageDraft
            default:              mapped = .genericText
            }
            self.pushModelOutput(content: content, type: mapped)
        }
        // A Composio Connect Link for an unauthorized toolkit becomes a "Connect
        // <App>" row in the panel. Dedupe by toolkit so repeated asks don't stack.
        realtimeClient.onConnectionLinkAvailable = { [weak self] toolkit, url in
            guard let self else { return }
            self.pendingConnections.removeAll { $0.toolkit == toolkit }
            self.pendingConnections.append(PendingConnection(toolkit: toolkit, redirectURL: url))
        }
        // A completed turn becomes a history entry in the drop panel.
        realtimeClient.onTurnCompleted = { [weak self] userPhrase, modelText in
            guard let self else { return }
            self.recordInteraction(userPhrase: userPhrase, modelText: modelText)
            // Log plain conversational turns (no tool) to the activity history.
            // Tool turns are logged from handleActivityChange's "✓" transition
            // instead, so they aren't double-counted here.
            if !self.turnUsedTool {
                self.appendHistory(Self.firstSentence(of: modelText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        // Track tool narration → result transitions for the history log, and note
        // when a turn used a tool so it isn't also logged as a plain turn.
        realtimeClient.$currentActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in self?.handleActivityChange(activity) }
            .store(in: &realtimeActivityCancellables)
        realtimeClient.$isToolActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in if active { self?.turnUsedTool = true } }
            .store(in: &realtimeActivityCancellables)
        // Open the persistent GPT-Realtime-2 WebSocket on launch and keep it
        // alive for the whole session (heartbeat every 25s).
        realtimeClient.connect()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    /// Maps a tool name to the short phrase shown in the notch bar's left zone
    /// while it runs. Returns nil for tools with no narration (the bar then shows
    /// the plain state text instead).
    private static func narrationPhrase(for toolName: String) -> String? {
        switch toolName {
        case "get_screen_context": return "looking at your screen"
        default: return nil
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        realtimeClient.disconnect()
        transientHideTask?.cancel()

        shortcutTransitionCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, mark the cursor visible now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
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
            print("🎤 Companion: push-to-talk PRESSED")
            guard !buddyDictationManager.isDictationInProgress else {
                print("🎤 Companion: ignored — capture already in progress")
                return
            }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                isOverlayVisible = true
            }

            // Barge-in: cut off any audio the model is still playing, and clear
            // any leftover pointing target from a previous interaction.
            realtimeClient.interruptPlayback()
            // Discard any leftover uncommitted audio from a prior press so this
            // capture starts with a clean input buffer (otherwise the model can
            // respond to a previous utterance).
            realtimeClient.clearAudioBuffer()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }

            ClickyAnalytics.trackPushToTalkStarted()

            // Stream mic audio straight to GPT-Realtime-2 as PCM16 chunks.
            voiceState = .listening
            // New user turn: no tool used yet (gates plain-turn history logging).
            turnUsedTool = false
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.buddyDictationManager.startRealtimeAudioStreaming { [weak self] pcm16Chunk in
                        // The tap fires on the audio render thread; hop to main
                        // (serially, to preserve chunk order) before sending.
                        DispatchQueue.main.async {
                            self?.realtimeClient.sendAudio(pcm16Chunk)
                        }
                    }
                } catch {
                    print("⚠️ Companion: couldn't start realtime audio streaming: \(error)")
                    // Reset capture state so a failed start doesn't block future presses.
                    self.buddyDictationManager.stopRealtimeAudioStreaming()
                    self.voiceState = .idle
                }
            }
        case .released:
            print("🎤 Companion: push-to-talk RELEASED")
            // Cancel the pending start task in case the user released the shortcut
            // before the async capture had a chance to begin.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil

            // Only commit + request a response if capture was actually running —
            // a too-fast press/release would otherwise commit an empty buffer.
            if buddyDictationManager.stopRealtimeAudioStreaming() {
                voiceState = .processing
                realtimeClient.commitAudio()
                // Inject any files dropped into the panel before asking for a
                // response, so the model sees them this turn. Then clear the queue.
                if !pendingFileContext.isEmpty || !pendingImageContext.isEmpty {
                    realtimeClient.sendUserContext(texts: pendingFileContext, images: pendingImageContext)
                    clearPendingAttachments()
                }
                // Attach files dropped on the notch drop zone, then clear the queue.
                if !pendingDroppedFiles.isEmpty {
                    realtimeClient.sendDroppedFiles(pendingDroppedFiles)
                    pendingDroppedFiles = []
                }
                realtimeClient.requestResponse()
            } else {
                print("🎤 Companion: released but no capture was active")
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        case .none:
            break
        }
    }

    // MARK: - Transient Cursor Hide

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for any pointing animation to finish, then fades out the overlay
    /// after a 1-second pause. Cancelled automatically if the user starts
    /// another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isOverlayVisible = false
        }
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

}
