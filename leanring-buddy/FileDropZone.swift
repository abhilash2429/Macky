//
//  FileDropZone.swift
//  leanring-buddy
//
//  Fills the open panel's content area when files are dragged onto the notch
//  (panelDisplayState == .fileDrop). A dashed drop target, the collected files as
//  removable chips, and a Confirm button that queues them on CompanionManager for
//  the next voice turn and returns the panel to idle.
//
//  Replaces the old AurenFileDropPanel: the new flow only collects URLs (no inline
//  extraction or send) — RealtimeClient.sendDroppedFiles extracts on the next
//  shortcut release. FileChip moved here from AurenFileDropPanel.
//

import SwiftUI
import UniformTypeIdentifiers

struct FileDropZone: View {
    /// The files collected so far this drop session, mirrored from panelDisplayState.
    let files: [URL]
    @ObservedObject var companionManager: CompanionManager

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            dropTarget

            if !files.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    ForEach(files, id: \.self) { url in
                        FileChip(url: url) {
                            companionManager.setDroppedFiles(files.filter { $0 != url })
                        }
                    }
                }
            }

            Button("Confirm") { companionManager.confirmDroppedFiles(files) }
                .dsPrimaryButtonStyle()
                .disabled(files.isEmpty)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.large)
            .strokeBorder(
                isTargeted ? DS.Colors.accent : DS.Colors.borderStrong,
                style: StrokeStyle(lineWidth: 1, dash: [6])
            )
            .frame(height: 90)
            .overlay(
                VStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20, weight: .light))
                    Text("Drop files here")
                        .font(.system(size: 11))
                }
                .foregroundStyle(isTargeted ? DS.Colors.accentText : DS.Colors.textSecondary)
            )
            .animation(.smooth(duration: 0.15), value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                ingest(providers)
                return true
            }
    }

    /// Resolves each provider to a file URL on the main actor and hands them to
    /// CompanionManager, which merges/dedupes into the drop list.
    private func ingest(_ providers: [NSItemProvider]) {
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

// MARK: - File Chip

struct FileChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Spacing.xs)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .fill(DS.Colors.surface2)
        )
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
