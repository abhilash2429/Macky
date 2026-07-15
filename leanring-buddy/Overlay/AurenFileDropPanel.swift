//
//  AurenFileDropPanel.swift
//  leanring-buddy
//
//  The file-input view shown in the open notch when files are dragged in (or
//  when the user opens the panel to attach something). It
//  is purely a collector: it gathers URLs + an optional prompt and hands them to
//  `onSend`. NotchContainerView owns the actual ingestion + pipeline hand-off so
//  this view stays dumb and reusable.
//

import SwiftUI
import UniformTypeIdentifiers

struct AurenFileDropPanel: View {
    @Binding var droppedURLs: [URL]
    /// Pipeline entry point: the collected files and the typed prompt.
    var onSend: ([URL], String) -> Void

    @State private var isTargeted = false
    @State private var promptText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !droppedURLs.isEmpty {
                attachedChips
            }
            askCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 9) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("Drop files here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("or drag straight onto the notch to attach")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Flat neutral wash at rest; accent highlight while a drag is
        // targeted (mirrors boring.notch's ShelfView drop-zone treatment).
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.015))
                .animation(.smooth(duration: 0.15), value: isTargeted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1.4, dash: [6, 4])
                )
                .animation(.smooth(duration: 0.15), value: isTargeted)
        )
    }

    // MARK: - Attached file chips (row between the drop zone and the ask card)

    private var attachedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(droppedURLs, id: \.self) { url in
                    FileChip(url: url) { droppedURLs.removeAll { $0 == url } }
                }
            }
        }
    }

    // MARK: - Ask card (separate, with accent send button)

    private var askCard: some View {
        HStack(spacing: 10) {
            TextField("Ask something about these files…", text: $promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.9))
                .onSubmit { sendIfReady() }

            Button { sendIfReady() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 29, height: 29)
                    // Full bright accent to match the reference; only softens when
                    // there's genuinely nothing to send.
                    .background(Circle().fill(canSend ? Color.accentColor : Color.accentColor.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.smooth(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !droppedURLs.isEmpty || !promptText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendIfReady() {
        guard canSend else { return }
        let urls = droppedURLs
        let prompt = promptText
        droppedURLs = []
        promptText = ""
        onSend(urls, prompt)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard
                    let data,
                    let urlString = String(data: data, encoding: .utf8),
                    let url = URL(string: urlString)
                else { return }
                DispatchQueue.main.async {
                    if !self.droppedURLs.contains(url) { self.droppedURLs.append(url) }
                }
            }
        }
    }
}

// MARK: - File Chip

struct FileChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(iconTint)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
            Button { onRemove() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private var iconName: String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.fill"
        case "png", "jpg", "jpeg", "webp", "gif": return "photo.fill"
        case "mp4", "mov", "avi", "mkv": return "video.fill"
        case "mp3", "wav", "m4a", "aac": return "music.note"
        case "zip", "tar", "gz", "rar": return "archivebox.fill"
        case "swift", "py", "js", "ts", "go", "rs": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    /// Leading-icon tint by file type: pdf red, images accent-blue, everything
    /// else the neutral secondary text color.
    private var iconTint: Color {
        switch url.pathExtension.lowercased() {
        case "pdf": return Color.red
        case "png", "jpg", "jpeg", "webp", "gif": return Color.accentColor
        default: return Color.white.opacity(0.6)
        }
    }
}
