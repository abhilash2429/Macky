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
    }

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerOrStatus
                .zIndex(2)

            if isOpen {
                openContent
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
        if isOpen {
            MackyPanelHeader(selectedPage: $panelPage, onClose: close)
                .frame(height: max(32, notch.effectiveClosedNotchHeight))
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
                AurenPanel(companionManager: companionManager, page: .home)
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

    private func close() {
        collapseTask?.cancel()
        guard !setupRequiresPanel else {
            open()
            return
        }
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
            // Keep the panel up while the user is in the middle of attaching files.
            if panelPage == .files && !fileDropURLs.isEmpty { return }
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
        HStack(spacing: 10) {
            MackyLogoView(size: 18)

            Text("Macky")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            HeaderIcon(systemName: "house.fill", isSelected: selectedPage == .home) { selectedPage = .home }
            HeaderIcon(systemName: "puzzlepiece.extension.fill", isSelected: selectedPage == .connectors) { selectedPage = .connectors }
            HeaderIcon(systemName: "paperclip", isSelected: selectedPage == .files) { selectedPage = .files }
            HeaderIcon(systemName: "gearshape.fill", isSelected: selectedPage == .settings) { selectedPage = .settings }
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(Circle().fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.06)))
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
                    MackyOnboardingWelcomeView(onContinue: goNext)
                case .microphone, .screenRecording, .screenContent, .accessibility, .calendar, .reminders:
                    MackyOnboardingPermissionView(
                        step: step,
                        isGranted: step.isGranted(companionManager),
                        onAllow: requestCurrentPermissionAndContinue,
                        onSkip: goNext
                    )
                case .hotkey:
                    MackyOnboardingHotkeyView(
                        companionManager: companionManager,
                        onContinue: goNext,
                        onSkip: goNext
                    )
                case .finished:
                    MackyOnboardingFinishedView(
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
                    .fill(index <= step.rawValue ? Color.white.opacity(0.82) : Color.white.opacity(0.14))
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
    case welcome
    case microphone
    case screenRecording
    case screenContent
    case accessibility
    case calendar
    case reminders
    case hotkey
    case finished

    var title: String {
        switch self {
        case .welcome: return "Macky"
        case .microphone: return "Enable Microphone"
        case .screenRecording: return "Enable Screen Recording"
        case .screenContent: return "Enable Screen Context"
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
        case .screenContent: return "macwindow"
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
            return "Macky needs microphone access to hear push-to-talk requests."
        case .screenRecording:
            return "Screen Recording lets Macky understand visible app context when you ask for help."
        case .screenContent:
            return "Screen context lets Macky attach the current page or selected content to a request."
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
            return "Audio capture only starts when you use push-to-talk."
        case .screenRecording, .screenContent:
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
        case .screenContent:
            return companionManager.hasScreenContentPermission
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
        case .screenContent:
            companionManager.requestScreenContentPermission()
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
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            MackyOnboardingGlow()

            VStack(spacing: 12) {
                Image(systemName: "capsule.portrait.fill")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: DS.Colors.accentText.opacity(0.42), radius: 24)

                VStack(spacing: 3) {
                    Text("Macky")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Welcome")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }

                Button(action: onContinue) {
                    Text("Get started")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            .padding(.bottom, 18)
        }
    }
}

private struct MackyOnboardingPermissionView: View {
    let step: MackyPanelOnboardingStep
    let isGranted: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : step.icon)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(isGranted ? DS.Colors.success : DS.Colors.accentText)
                .padding(.top, 6)

            VStack(spacing: 8) {
                Text(step.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text(step.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }

            if !step.privacyNote.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(step.privacyNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: 430, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.055)))
            }

            HStack(spacing: 10) {
                Button("Not Now", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Button(action: onAllow) {
                    Text(isGranted ? "Continue" : "Allow Access")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(MackyOnboardingGlow().opacity(0.58))
    }
}

private struct MackyOnboardingHotkeyView: View {
    @ObservedObject var companionManager: CompanionManager
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)

            VStack(spacing: 7) {
                Text("Set Push-to-Talk")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("This shortcut is the only trigger you need; setup stays in the panel.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
            }

            HotkeySettingsView(companionManager: companionManager)
                .padding(12)
                .frame(maxWidth: 430)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Button("Continue", action: onContinue)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white))
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(MackyOnboardingGlow().opacity(0.58))
    }
}

private struct MackyOnboardingFinishedView: View {
    let hasAllPermissions: Bool
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText)

            Text("You're All Set")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(hasAllPermissions ? "Macky is ready in the notch." : "You can finish now and grant remaining access later in panel settings.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            Button(action: onFinish) {
                Text("Start using Macky")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(MackyOnboardingGlow())
    }
}

private struct MackyOnboardingGlow: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.accentText.opacity(0.20))
                .frame(width: 220, height: 220)
                .blur(radius: 38)
                .offset(y: -34)
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 130, height: 130)
                .blur(radius: 28)
                .offset(x: -82, y: 70)
        }
        .allowsHitTesting(false)
    }
}
