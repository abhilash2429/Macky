//
//  FileDropZone.swift
//  leanring-buddy
//
//  The bottom section of the drop panel. Accepts dragged files and queues their
//  contents (or images) onto CompanionManager for the next voice interaction:
//   - text/code/markdown → file text
//   - PDF → extracted text (PDFKit; filename-only fallback if extraction fails)
//   - image → PNG data injected as an image input
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct FileDropZone: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 8) {
            if !companionManager.pendingAttachmentNames.isEmpty {
                attachmentChips
            }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundColor(.white.opacity(isDragOver ? 0.5 : 0.2))
                .overlay(
                    Text("drop files for context")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                )
                .frame(height: 70)
                .onDrop(of: [.fileURL, .image, .pdf, .plainText], isTargeted: $isDragOver) { providers in
                    handleDrop(providers)
                    return true
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Small confirmation chips for currently queued attachments.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(companionManager.pendingAttachmentNames, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.white.opacity(0.12))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Loads each dropped item's file URL off the main thread, then routes it to
    /// the right CompanionManager queue on the main actor.
    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let name = url.lastPathComponent
                let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension)

                if let contentType, contentType.conforms(to: .image) {
                    ingestImage(at: url, name: name)
                } else if let contentType, contentType.conforms(to: .pdf) {
                    ingestPDF(at: url, name: name)
                } else {
                    ingestText(at: url, name: name)
                }
            }
        }
    }

    private func ingestImage(at url: URL, name: String) {
        // Re-encode to PNG so the injected data URL format is predictable.
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        Task { @MainActor in
            companionManager.attachDroppedImage(png, name: name)
        }
    }

    private func ingestPDF(at url: URL, name: String) {
        let extracted = PDFDocument(url: url)?.string ?? ""
        Task { @MainActor in
            if extracted.isEmpty {
                // Couldn't extract text — queue a filename note so the model at
                // least knows a PDF was attached.
                print("⚠️ FileDropZone: no extractable text in \(name)")
                companionManager.attachDroppedText("(attached PDF, text not extractable)", name: name)
            } else {
                companionManager.attachDroppedText(extracted, name: name)
            }
        }
    }

    private func ingestText(at url: URL, name: String) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        Task { @MainActor in
            if text.isEmpty {
                print("⚠️ FileDropZone: couldn't read text from \(name)")
                companionManager.attachDroppedText("(attached file \"\(name)\", contents unreadable)", name: name)
            } else {
                companionManager.attachDroppedText(text, name: name)
            }
        }
    }
}
