//
//  NotchContainerView.swift
//  leanring-buddy
//
//  The SwiftUI root hosted inside the notch NSPanel — Speed's equivalent of
//  BoringNotch's ContentView, trimmed to what we need. It draws the morphing
//  black NotchShape and swaps its contents by state:
//
//    • closed → AurenStatusBar when the assistant is active, else a bare notch
//    • open   → AurenPanel, which owns its own header and switches content by
//               CompanionManager.panelDisplayState (idle / modelOutput / fileDrop
//               / connectors / settings).
//
//  Interaction: hovering or tapping the notch opens it; the cursor leaving
//  collapses it after a short delay (except mid-review or mid-drop). Dragging a
//  file routes through CompanionManager.beginFileDrop, which flips
//  panelDisplayState to .fileDrop and auto-opens the panel via the .onChange
//  observer. Opening/closing just flips NotchUIModel.notchState — the controller
//  resizes the host panel frame in response.
//

import SwiftUI
import UniformTypeIdentifiers

struct NotchContainerView: View {
    @EnvironmentObject var notch: NotchUIModel
    @ObservedObject var companionManager: CompanionManager

    @State private var isHovering = false
    @State private var collapseTask: Task<Void, Never>?

    /// One timeline shared with the AppKit window resize (NotchPanelController) so
    /// the content morph and the host window move together — see NotchConstants.
    private let morphAnimation = Animation.timingCurve(
        NotchConstants.morphControlPoints.c0x,
        NotchConstants.morphControlPoints.c0y,
        NotchConstants.morphControlPoints.c1x,
        NotchConstants.morphControlPoints.c1y,
        duration: NotchConstants.morphDuration
    )

    private var isOpen: Bool { notch.notchState == .open }

    /// True when the assistant is doing anything worth showing in the closed bar.
    private var isAssistantActive: Bool {
        companionManager.voiceState != .idle || companionManager.toolCallActive
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
                    // A 1pt black cap hides the shape's top corner seam against
                    // the screen edge, same trick BoringNotch uses.
                    Rectangle()
                        .fill(.black)
                        .frame(height: 1)
                        .padding(.horizontal, isOpen ? NotchConstants.openedCornerRadius.top : NotchConstants.closedCornerRadius.top)
                }
                .shadow(color: (isOpen || isHovering) ? .black.opacity(0.7) : .clear, radius: 6)
                .animation(morphAnimation, value: notch.notchState)
                .contentShape(Rectangle())
                .onHover { handleHover($0) }
                .onTapGesture { open() }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    ingestDroppedProviders(providers)
                    return true
                }
        }
        .frame(
            maxWidth: NotchConstants.windowSize.width,
            maxHeight: NotchConstants.maxOpenHeight + NotchConstants.shadowPadding,
            alignment: .top
        )
        .preferredColorScheme(.dark)
        // The model pushing output or a file being dropped flips panelDisplayState;
        // auto-open the panel onto that content. open() is idempotent (guards !isOpen).
        .onChange(of: companionManager.panelDisplayState) { _, newState in
            switch newState {
            case .modelOutput, .fileDrop: open()
            default: break
            }
        }
    }

    // MARK: - Morphing body

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerOrStatus
                .zIndex(2)

            if isOpen {
                openContent
                    .transition(
                        .scale(scale: 0.85, anchor: .top)
                            .combined(with: .opacity)
                    )
                    .zIndex(1)
                    .allowsHitTesting(true)
            }
        }
        // Inset open content so it clears the shape's rounded corners. The height
        // is exact (driven by the measured openContentHeight), so no bottom inset.
        .padding(.horizontal, isOpen ? NotchConstants.openedCornerRadius.bottom : 0)
        .frame(
            width: isOpen ? NotchConstants.openNotchSize.width : nil,
            height: isOpen ? notch.openContentHeight : nil,
            alignment: .top
        )
    }

    /// Top zone: the active status bar when closed. When open, AurenPanel provides
    /// its own pinned header, so this stays empty.
    @ViewBuilder
    private var headerOrStatus: some View {
        if isOpen {
            EmptyView()
        } else if isAssistantActive {
            AurenStatusBar(companionManager: companionManager)
        } else {
            // Bare notch: an empty black strip exactly the cutout footprint.
            Rectangle()
                .fill(.clear)
                .frame(
                    width: max(0, notch.closedNotchSize.width),
                    height: notch.effectiveClosedNotchHeight
                )
        }
    }

    /// AurenPanel owns the header + separator + scroll area and switches its inner
    /// content by CompanionManager.panelDisplayState.
    private var openContent: some View {
        AurenPanel(companionManager: companionManager)
    }

    // MARK: - Open / close

    private func open() {
        collapseTask?.cancel()
        guard !isOpen else { return }
        // The morph is animated once, by the .animation(morphAnimation, value:)
        // modifier on the body — no withAnimation here (that double-animated the
        // state change and interrupted the shape's corner-radius interpolation).
        notch.open()
    }

    private func close() {
        collapseTask?.cancel()
        guard isOpen else { return }
        notch.close()
        // Collapse ≠ discard: leave panelDisplayState as-is so reopening resumes a
        // pending review/drop. Idle/connectors/settings simply reopen where they were.
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

    /// Collapse shortly after the cursor leaves — unless a model-output review or a
    /// file drop is in progress (those stay put until the user acts on them).
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !isHovering else { return }
            switch companionManager.panelDisplayState {
            case .modelOutput, .fileDrop: return
            default: close()
            }
        }
    }

    // MARK: - File drop

    /// Resolves dropped providers to file URLs and hands them to CompanionManager,
    /// which flips panelDisplayState to .fileDrop (auto-opening the panel via the
    /// .onChange observer). Extraction happens later, in RealtimeClient.sendDroppedFiles.
    private func ingestDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard
                    let data,
                    let urlString = String(data: data, encoding: .utf8),
                    let url = URL(string: urlString)
                else { return }
                Task { @MainActor in
                    companionManager.beginFileDrop([url])
                }
            }
        }
    }
}