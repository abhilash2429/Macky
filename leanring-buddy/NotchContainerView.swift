//
//  NotchContainerView.swift
//  leanring-buddy
//
//  SwiftUI root for Macky's single product surface: the closed notch/status bar
//  and the expanded panel. Auth, onboarding, connectors, settings, files, and
//  assistant activity all route through this view.
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchContainerView: View {
    @EnvironmentObject var notch: NotchUIModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var authManager = AuthManager.shared

    enum PanelPage {
        case home
        case connectors
        case settings
        case files
    }

    @State private var panelPage: PanelPage = .home
    @State private var fileDropURLs: [URL] = []
    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var focusedEditAutoCollapseTask: Task<Void, Never>?
    @State private var focusedEditAutoPresentationID: UUID?

    private let morphAnimation = Animation.timingCurve(
        NotchConstants.morphControlPoints.c0x,
        NotchConstants.morphControlPoints.c0y,
        NotchConstants.morphControlPoints.c1x,
        NotchConstants.morphControlPoints.c1y,
        duration: NotchConstants.morphDuration
    )

    private var isOpen: Bool { notch.notchState == .open }

    private var setupRequiresPanel: Bool {
        authManager.phase != .authenticated || !companionManager.hasCompletedPanelOnboarding
    }

    private var currentNotchShape: NotchShape {
        let radii = isOpen ? NotchConstants.openedCornerRadius : NotchConstants.closedCornerRadius
        return NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
    }

    var body: some View {
        VStack(spacing: 0) {
            notchBody
                .background(.black)
                .clipShape(currentNotchShape)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 1)
                        .padding(.horizontal, isOpen ? NotchConstants.openedCornerRadius.top : NotchConstants.closedCornerRadius.top)
                }
                .shadow(color: (isOpen || isHovering) ? .black.opacity(0.7) : .clear, radius: 7)
                .animation(morphAnimation, value: notch.notchState)
                .contentShape(Rectangle())
                .onHover { handleHover($0) }
                .onTapGesture { open() }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    panelPage = .files
                    open()
                    ingestDroppedProviders(providers)
                    return true
                }
                .onChange(of: isDropTargeted) { _, targeted in
                    // As soon as a file drag hovers the notch, expand and jump to the
                    // Files page so there's a real drop surface. onHover doesn't fire
                    // reliably mid-drag, so this is what actually opens the panel.
                    if targeted {
                        collapseTask?.cancel()
                        panelPage = .files
                        open()
                    } else {
                        scheduleCollapse()
                    }
                }
        }
        .frame(maxWidth: NotchConstants.windowSize.width, maxHeight: NotchConstants.windowSize.height, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear(perform: ensureSetupPanelIsVisible)
        .onChange(of: authManager.phase) { _, _ in
            ensureSetupPanelIsVisible()
        }
        .onChange(of: companionManager.hasCompletedPanelOnboarding) { _, _ in
            ensureSetupPanelIsVisible()
        }
        .onChange(of: companionManager.isAssistantActive) { _, active in
            // When a turn finishes, resume the normal collapse timer (unless the
            // user is still hovering). The active-state guards in close()/
            // scheduleCollapse() keep the notch live until this fires.
            if !active { scheduleCollapse() }
        }
        .onChange(of: companionManager.focusedEditPresentation?.id) { _, _ in
            presentFocusedEditIfNeeded()
        }
    }

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerOrStatus
                .zIndex(2)

            if isOpen {
                openContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Gradients.panelSubtle)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .padding(.horizontal, isOpen ? NotchConstants.openedCornerRadius.bottom : 0)
        .padding([.horizontal, .bottom], isOpen ? 12 : 0)
        .frame(
            width: isOpen ? NotchConstants.openNotchSize.width : nil,
            height: isOpen ? NotchConstants.openNotchSize.height : nil,
            alignment: .top
        )
    }

    @ViewBuilder
    private var headerOrStatus: some View {
        if isOpen && setupRequiresPanel {
            // Auth/onboarding own the full open-panel height; the header's tabs,
            // gear, and close button are all inert while setup is required.
            EmptyView()
        } else if isOpen {
            MackyPanelHeader(selectedPage: $panelPage, onClose: { close(userInitiated: true) })
                .frame(height: max(28, notch.effectiveClosedNotchHeight))
        } else if companionManager.isAssistantActive {
            AurenStatusBar(companionManager: companionManager)
        } else {
            NotchIdleBar()
        }
    }

    @ViewBuilder
    private var openContent: some View {
        if authManager.phase != .authenticated {
            AuthView(authManager: authManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !companionManager.hasCompletedPanelOnboarding {
            MackyPanelOnboardingView(companionManager: companionManager)
        } else {
            switch panelPage {
            case .home:
                AurenPanel(companionManager: companionManager, page: .home, onOpenConnectors: { panelPage = .connectors })
            case .connectors:
                AurenPanel(companionManager: companionManager, page: .connectors)
            case .settings:
                AurenPanel(companionManager: companionManager, page: .settings)
            case .files:
                AurenFileDropPanel(droppedURLs: $fileDropURLs) { urls, prompt in
                    handleSend(urls: urls, prompt: prompt)
                }
            }
        }
    }

    private func open() {
        collapseTask?.cancel()
        guard !isOpen else { return }
        notch.open()
    }

    /// Collapses the expanded panel back to the closed notch bar. `userInitiated` is
    /// the explicit close button (top-right arrow): it always collapses. Automatic
    /// callers (the hover collapse timer) leave it false so the panel stays open
    /// mid-turn — but note continuous-listening mode keeps `isAssistantActive` true
    /// for the whole session, so without the explicit bypass the close button would
    /// never work while that mode is on. Collapsing doesn't go fully invisible while
    /// the assistant is active: the closed bar still shows the live status.
    private func close(userInitiated: Bool = false) {
        collapseTask?.cancel()
        guard !setupRequiresPanel else {
            open()
            return
        }
        // Never auto-collapse mid-turn: keep the live status bar (Listening →
        // Thinking → Speaking) visible for the whole interaction instead of
        // flickering closed. The explicit close button overrides this.
        guard userInitiated || !companionManager.isAssistantActive else { return }
        guard isOpen else { return }
        notch.close()
        panelPage = .home
        fileDropURLs = []
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            collapseTask?.cancel()
            open()
        } else {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !isHovering else { return }
            guard !isDropTargeted else { return }
            guard !setupRequiresPanel else { return }
            guard focusedEditAutoPresentationID == nil else { return }
            // Stay open while the assistant is listening/thinking/speaking so the
            // notch is live for the whole push-to-talk turn.
            guard !companionManager.isAssistantActive else { return }
            // Keep the panel up while the user is in the middle of attaching files.
            if panelPage == .files && !fileDropURLs.isEmpty { return }
            close()
        }
    }

    /// Focused text edits are a concrete outcome worth showing. They reuse Home
    /// rather than introducing another panel page, then collapse after a short hold
    /// unless the user keeps the pointer over the panel.
    private func presentFocusedEditIfNeeded() {
        guard let presentation = companionManager.focusedEditPresentation,
              presentation.shouldAutoExpand else { return }
        collapseTask?.cancel()
        focusedEditAutoCollapseTask?.cancel()
        focusedEditAutoPresentationID = presentation.id
        panelPage = .home
        open()

        focusedEditAutoCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                  focusedEditAutoPresentationID == presentation.id else { return }
            focusedEditAutoPresentationID = nil
            focusedEditAutoCollapseTask = nil
            guard !isHovering, !companionManager.isAssistantActive else { return }
            close()
        }
    }

    private func ensureSetupPanelIsVisible() {
        guard setupRequiresPanel else { return }
        panelPage = .home
        collapseTask?.cancel()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard setupRequiresPanel else { return }
            open()
        }
    }

    private func handleSend(urls: [URL], prompt: String) {
        Task { @MainActor in
            for url in urls { await ingest(url: url) }

            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            var texts = companionManager.pendingFileContext
            if !trimmedPrompt.isEmpty { texts.append(trimmedPrompt) }
            let images = companionManager.pendingImageContext
            guard !texts.isEmpty || !images.isEmpty else { close(); return }

            companionManager.submitPanelContext(texts: texts, images: images)
            companionManager.clearPendingAttachments()
            close()
        }
    }

    private func ingestDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard
                    let data,
                    let urlString = String(data: data, encoding: .utf8),
                    let url = URL(string: urlString)
                else { return }
                DispatchQueue.main.async {
                    if !self.fileDropURLs.contains(url) { self.fileDropURLs.append(url) }
                }
            }
        }
    }

    private func ingest(url: URL) async {
        let name = url.lastPathComponent
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)

        if let contentType, contentType.conforms(to: .image) {
            if let image = NSImage(contentsOf: url),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                companionManager.attachDroppedImage(png, name: name)
            }
        } else if let contentType, contentType.conforms(to: .pdf) {
            let extracted = PDFDocument(url: url)?.string ?? ""
            companionManager.attachDroppedText(extracted.isEmpty ? "(attached PDF, text not extractable)" : extracted, name: name)
        } else {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            companionManager.attachDroppedText(text.isEmpty ? "(attached file \"\(name)\", contents unreadable)" : text, name: name)
        }
    }
}

private struct MackyPanelHeader: View {
    @Binding var selectedPage: NotchContainerView.PanelPage
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PanelTabBar(
                tabs: [
                    .init(id: "home", icon: "house", label: "Home"),
                    .init(id: "connectors", icon: "square.grid.2x2", label: "Connectors")
                ],
                selectedID: selectedPage == .connectors ? "connectors" : "home",
                onSelect: { id in
                    selectedPage = id == "connectors" ? .connectors : .home
                }
            )

            Spacer()

            HeaderIcon(systemName: "gearshape", isSelected: selectedPage == .settings) { selectedPage = .settings }
            HeaderIcon(systemName: "chevron.up", isSelected: false, action: onClose)
        }
        .padding(.horizontal, 4)
    }
}

private struct HeaderIcon: View {
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                .frame(width: 27, height: 27)
                .background(
                    Circle()
                        .fill(isSelected ? Color(nsColor: .secondarySystemFill) : Color.white.opacity(0.05))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0.07), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MackyPanelOnboardingView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var step: MackyPanelOnboardingStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            onboardingProgress
                .padding(.horizontal, 24)
                .padding(.top, 8)

            ZStack {
                switch step {
                case .welcome:
                    MackyOnboardingWelcomeView(step: step, onContinue: goNext)
                case .microphone, .screenRecording, .accessibility, .calendar, .reminders:
                    MackyOnboardingPermissionView(
                        step: step,
                        isGranted: step.isGranted(companionManager),
                        onAllow: requestCurrentPermissionAndContinue,
                        onSkip: goNext
                    )
                case .hotkey:
                    MackyOnboardingHotkeyView(
                        step: step,
                        companionManager: companionManager,
                        onContinue: goNext,
                        onSkip: goNext
                    )
                case .finished:
                    MackyOnboardingFinishedView(
                        step: step,
                        hasAllPermissions: companionManager.allPermissionsGranted,
                        onFinish: { companionManager.setPanelOnboardingComplete(true) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.26), value: step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onboardingProgress: some View {
        HStack(spacing: 5) {
            ForEach(0..<MackyPanelOnboardingStep.allCases.count, id: \.self) { index in
                Capsule()
                    .fill(index <= step.rawValue ? Color.accentColor : Color.white.opacity(0.14))
                    .frame(height: 3)
            }
        }
    }

    private func requestCurrentPermissionAndContinue() {
        step.requestPermission(companionManager)
        goNext()
    }

    private func goNext() {
        guard let nextStep = MackyPanelOnboardingStep(rawValue: step.rawValue + 1) else {
            companionManager.setPanelOnboardingComplete(true)
            return
        }

        withAnimation(.easeInOut(duration: 0.26)) {
            step = nextStep
        }
    }
}

private enum MackyPanelOnboardingStep: Int, CaseIterable {
    // Microphone and accessibility gate the core push-to-talk loop (accessibility
    // specifically gates whether the global hotkey fires at all), so they come
    // first — ahead of the supplementary screen-recording/calendar/reminders
    // steps, and before the hotkey step that depends on accessibility.
    case welcome
    case microphone
    case accessibility
    case screenRecording
    case calendar
    case reminders
    case hotkey
    case finished

    var title: String {
        switch self {
        case .welcome: return "Macky"
        case .microphone: return "Enable Microphone"
        case .screenRecording: return "Enable Screen Recording"
        case .accessibility: return "Enable Accessibility"
        case .calendar: return "Enable Calendar"
        case .reminders: return "Enable Reminders"
        case .hotkey: return "Set Push-to-Talk"
        case .finished: return "You're All Set"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "capsule.portrait.fill"
        case .microphone: return "mic.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .hotkey: return "keyboard"
        case .finished: return "sparkles"
        }
    }

    var description: String {
        switch self {
        case .welcome:
            return "Voice, tools, approvals, connectors, and setup all happen from the notch panel."
        case .microphone:
            return "Macky needs microphone access to hear your push-to-talk requests. Audio capture only starts when you hold the key."
        case .screenRecording:
            return "Screen Recording lets Macky understand visible app context when you ask for help."
        case .accessibility:
            return "Accessibility lets the global hotkey and system-level actions work reliably."
        case .calendar:
            return "Calendar access powers the in-panel schedule view and scheduling tasks."
        case .reminders:
            return "Reminders access powers the in-panel reminder list and task updates."
        case .hotkey:
            return "Choose the modifier combo that wakes Macky without opening another UI."
        case .finished:
            return "Macky is ready to work from the notch."
        }
    }

    var privacyNote: String {
        switch self {
        case .welcome, .hotkey, .finished:
            return ""
        case .microphone:
            return "Nothing is recorded in the background — only while the key is held."
        case .screenRecording:
            return "Screen context is sent only when Macky needs it for your request."
        case .accessibility:
            return "This is used for control and hotkey behavior, not background browsing."
        case .calendar:
            return "Calendar data stays in the panel unless you ask Macky to use it."
        case .reminders:
            return "Reminder data is used for your visible reminder workflow."
        }
    }

    func isGranted(_ companionManager: CompanionManager) -> Bool {
        switch self {
        case .welcome, .hotkey, .finished:
            return false
        case .microphone:
            return companionManager.hasMicrophonePermission
        case .screenRecording:
            return companionManager.hasScreenRecordingPermission
        case .accessibility:
            return companionManager.hasAccessibilityPermission
        case .calendar:
            return companionManager.hasCalendarPermission
        case .reminders:
            return companionManager.hasRemindersPermission
        }
    }

    func requestPermission(_ companionManager: CompanionManager) {
        switch self {
        case .welcome, .hotkey, .finished:
            return
        case .microphone:
            companionManager.requestMicrophonePermission()
        case .screenRecording:
            companionManager.requestScreenRecordingPermission()
        case .accessibility:
            companionManager.requestAccessibilityPermission()
        case .calendar:
            companionManager.requestCalendarPermission()
        case .reminders:
            companionManager.requestRemindersPermission()
        }
    }
}

private struct MackyOnboardingWelcomeView: View {
    let step: MackyPanelOnboardingStep
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 11) {
                MackyGlyphLogo(size: 46, glow: true)

                VStack(spacing: 3) {
                    Text("Macky")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Welcome")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.56))
                    Text(step.description)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                        .padding(.top, 3)
                }

                Button(action: onContinue) {
                    Text("Get started")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.top, 9)
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }
}

private struct MackyOnboardingPermissionView: View {
    let step: MackyPanelOnboardingStep
    let isGranted: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            // 54px rounded icon tile with a soft accent wash.
            Image(systemName: isGranted ? "checkmark.circle.fill" : step.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isGranted ? Color.green : Color.accentColor)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill((isGranted ? Color.green : Color.accentColor).opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder((isGranted ? Color.green : Color.accentColor).opacity(0.28), lineWidth: 1)
                )
                .padding(.top, 4)

            VStack(spacing: 7) {
                Text(step.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))

                Text(step.description)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            if !step.privacyNote.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text(step.privacyNote)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 380, alignment: .center)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.055)))
            }

            HStack(spacing: 11) {
                Button("Not now", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))

                Button(action: onAllow) {
                    Text(isGranted ? "Continue" : "Allow access")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }
}

private struct MackyOnboardingHotkeyView: View {
    let step: MackyPanelOnboardingStep
    @ObservedObject var companionManager: CompanionManager
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // 54px rounded icon tile with a soft accent wash — matches the other
            // onboarding steps' icon tiles.
            Image(systemName: step.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                )

            VStack(spacing: 5) {
                Text(step.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text(step.description)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            HotkeySettingsView(companionManager: companionManager)
                .padding(10)
                .frame(maxWidth: 340)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 9) {
                Button("Not now", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))

                Button("Continue", action: onContinue)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }
}

private struct MackyOnboardingFinishedView: View {
    let step: MackyPanelOnboardingStep
    let hasAllPermissions: Bool
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            // 54px rounded icon tile with a soft accent wash — matches the other
            // onboarding steps' icon tiles.
            Image(systemName: step.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                )

            Text(step.title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))

            Text(hasAllPermissions ? step.description : "You can finish now and grant remaining access later in panel settings.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button(action: onFinish) {
                Text("Start using Macky")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }
}

/// Ported from boring.notch's `components/Settings/EditPanelView.swift` so the
/// onboarding steps share one translucent background instead of each picking its
/// own flat color.
private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = NSVisualEffectView.State.active
        visualEffectView.isEmphasized = true
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context _: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
