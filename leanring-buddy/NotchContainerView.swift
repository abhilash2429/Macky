//
//  NotchContainerView.swift
//  leanring-buddy
//
//  The SwiftUI root hosted inside the notch NSPanel — Speed's equivalent of
//  BoringNotch's ContentView, trimmed to what we need. It draws the morphing
//  black NotchShape and swaps its contents by state:
//
//    • closed → AurenStatusBar when the assistant is active, else a bare notch
//    • open   → a slim header + either AurenPanel (history/calendar/reminders)
//               or AurenFileDropPanel (when files were dragged in)
//
//  Interaction: hovering or tapping the notch opens it; the cursor leaving
//  collapses it after a short delay; dragging a file onto it opens the
//  file-input view. Opening/closing just flips NotchUIModel.notchState — the
//  controller resizes the host panel frame in response.
//
//  Ingestion (PDF/text/image extraction) and the pipeline hand-off live here so
//  AurenFileDropPanel stays a dumb collector. The extraction mirrors Speed's old
//  FileDropZone, and the hand-off reuses RealtimeClient.sendUserContext +
//  requestResponse plus CompanionManager's pending-context queues.
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchContainerView: View {
    @EnvironmentObject var notch: NotchUIModel
    @ObservedObject var companionManager: CompanionManager

    /// Which view fills the open panel. Drag-in switches to .fileInput.
    private enum OpenView { case home, fileInput }
    @State private var openView: OpenView = .home
    @State private var fileDropURLs: [URL] = []

    @State private var isHovering = false
    @State private var collapseTask: Task<Void, Never>?

    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

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
                .animation(isOpen ? openAnimation : closeAnimation, value: notch.notchState)
                .contentShape(Rectangle())
                .onHover { handleHover($0) }
                .onTapGesture { open() }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    openView = .fileInput
                    open()
                    ingestDroppedProviders(providers)
                    return true
                }
        }
        .frame(
            maxWidth: NotchConstants.windowSize.width,
            maxHeight: NotchConstants.windowSize.height,
            alignment: .top
        )
        .preferredColorScheme(.dark)
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
        .padding(.horizontal, isOpen ? NotchConstants.openedCornerRadius.bottom : 0)
        .padding([.horizontal, .bottom], isOpen ? 12 : 0)
        .frame(
            width: isOpen ? NotchConstants.openNotchSize.width : nil,
            height: isOpen ? NotchConstants.openNotchSize.height : nil,
            alignment: .top
        )
    }

    /// Top zone: the active status bar when closed, a slim header when open.
    @ViewBuilder
    private var headerOrStatus: some View {
        if isOpen {
            AurenHeader(onClose: close)
                .frame(height: max(24, notch.effectiveClosedNotchHeight))
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

    @ViewBuilder
    private var openContent: some View {
        switch openView {
        case .home:
            AurenPanel(companionManager: companionManager)
        case .fileInput:
            AurenFileDropPanel(droppedURLs: $fileDropURLs) { urls, prompt in
                handleSend(urls: urls, prompt: prompt)
            }
        }
    }

    // MARK: - Open / close

    private func open() {
        collapseTask?.cancel()
        guard !isOpen else { return }
        withAnimation(openAnimation) { notch.open() }
    }

    private func close() {
        collapseTask?.cancel()
        guard isOpen else { return }
        withAnimation(closeAnimation) { notch.close() }
        // Reset to the home view once collapsed so the next open starts clean.
        openView = .home
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

    /// Collapse shortly after the cursor leaves — unless a file-input session is
    /// mid-flight (the user may be reaching for the text field).
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !isHovering else { return }
            if openView == .fileInput && !fileDropURLs.isEmpty { return }
            close()
        }
    }

    // MARK: - File ingestion + pipeline hand-off

    /// Called on Send: queue the files as Speed context, attach the typed prompt,
    /// then ask the model to respond — the same path push-to-talk uses, minus the
    /// audio commit. Empty input is a no-op.
    private func handleSend(urls: [URL], prompt: String) {
        Task { @MainActor in
            for url in urls { await ingest(url: url) }

            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            var texts = companionManager.pendingFileContext
            if !trimmedPrompt.isEmpty { texts.append(trimmedPrompt) }
            let images = companionManager.pendingImageContext

            guard !texts.isEmpty || !images.isEmpty else { close(); return }

            companionManager.realtimeClient.sendUserContext(texts: texts, images: images)
            companionManager.realtimeClient.requestResponse()
            // Clear the queues so the next push-to-talk turn doesn't re-inject
            // this context. (pendingAttachmentNames is private(set) and only read
            // by the retired drop panel, so leaving it is harmless.)
            companionManager.pendingFileContext = []
            companionManager.pendingImageContext = []
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

    /// Mirrors Speed's old FileDropZone routing: images → PNG, PDF → extracted
    /// text (filename note on failure), everything else → UTF-8 text.
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
            companionManager.attachDroppedText(
                extracted.isEmpty ? "(attached PDF, text not extractable)" : extracted,
                name: name
            )
        } else {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            companionManager.attachDroppedText(
                text.isEmpty ? "(attached file \"\(name)\", contents unreadable)" : text,
                name: name
            )
        }
    }
}

// MARK: - Slim open-state header

private struct AurenHeader: View {
    var onClose: () -> Void

    var body: some View {
        HStack {
            Text("Auren")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}