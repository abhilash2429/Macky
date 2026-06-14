//
//  AurenFileDropPanel.swift
//  leanring-buddy
//
//  The file-input view shown in the open notch when files are dragged in (or
//  when the user opens the panel to attach something). Ported from the Auren
//  fork's FileDropPanel; the unused BoringViewModel dependency was removed. It
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
        VStack(alignment: .leading, spacing: 10) {
            fileListOrHint
            Divider().background(Color.white.opacity(0.12))
            promptRow
        }
        .padding(12)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isTargeted ? 0.08 : 0.04))
                .animation(.smooth(duration: 0.15), value: isTargeted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.white.opacity(0.3) : Color.white.opacity(0.08),
                    lineWidth: 1
                )
                .animation(.smooth(duration: 0.15), value: isTargeted)
        )
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var fileListOrHint: some View {
        if droppedURLs.isEmpty {
            dropHint
        } else {
            fileChipScroll
        }
    }

    private var dropHint: some View {
        HStack {
            Spacer()
            VStack(spacing: 5) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.gray)
                Text("Drop files here")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            .padding(.vertical, 8)
            Spacer()
        }
    }

    private var fileChipScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(droppedURLs, id: \.self) { url in
                    FileChip(url: url) { droppedURLs.removeAll { $0 == url } }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var promptRow: some View {
        HStack(spacing: 8) {
            TextField("Ask something about these files…", text: $promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onSubmit { sendIfReady() }
            sendButton
        }
    }

    private var sendButton: some View {
        Button { sendIfReady() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(canSend ? Color.white : Color.gray.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .animation(.smooth(duration: 0.15), value: canSend)
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
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(.gray)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
            Button { onRemove() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
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
}