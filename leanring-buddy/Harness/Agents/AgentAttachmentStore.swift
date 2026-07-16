//
//  AgentAttachmentStore.swift
//  leanring-buddy
//

import CryptoKit
import Foundation

/// Owns the encrypted local files exposed to a General Agent task. Source URLs are
/// never handed to the runtime directly: every accepted attachment is copied into a
/// versioned, authenticated container inside this root.
actor AgentAttachmentStore: AgentAttachmentAccessing {
    static let maximumAttachmentCount = 10
    static let maximumTotalBytes: Int64 = 50 * 1024 * 1024
    static let maximumChunkByteCount: Int64 = 1024 * 1024

    /// Container chunks are deliberately smaller than a tool read. A 1 MiB request can
    /// cross several chunks, but only its intersecting chunks ever need decryption.
    static let plaintextContainerChunkByteCount: Int64 = 64 * 1024
    static let encryptedContainerHeaderByteCount = 41
    static let encryptedChunkLengthByteCount = 4

    private static let encryptedChunkCombinedOverheadByteCount: Int64 = 28
    private static let containerVersion: UInt8 = 1
    private static let containerMagic = Data([0x4D, 0x41, 0x43, 0x4B, 0x59, 0x41, 0x54, 0x54])

    private let rootDirectory: URL
    private let keyProvider: AgentEncryptionKeyProviding
    private let fileManager: FileManager

    init(
        rootDirectory: URL = AgentAttachmentStore.defaultRootDirectory(),
        keyProvider: AgentEncryptionKeyProviding = AgentKeychainKeyProvider(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    func copyAttachments(from sourceURLs: [URL], for taskID: UUID) async throws -> [AgentAttachment] {
        guard sourceURLs.count <= Self.maximumAttachmentCount else {
            throw AgentAttachmentError.tooManyFiles(limit: Self.maximumAttachmentCount)
        }

        var sourceFiles: [(url: URL, byteCount: Int64)] = []
        var totalByteCount: Int64 = 0
        for sourceURL in sourceURLs {
            let didAccessSecurityScopedURL = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScopedURL {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resourceValues.isRegularFile == true else {
                throw AgentAttachmentError.notAFile(sourceURL.lastPathComponent)
            }
            let byteCount = Int64(resourceValues.fileSize ?? 0)
            totalByteCount += byteCount
            guard totalByteCount <= Self.maximumTotalBytes else {
                throw AgentAttachmentError.totalSizeExceeded(limit: Self.maximumTotalBytes)
            }
            sourceFiles.append((sourceURL, byteCount))
        }

        guard !sourceFiles.isEmpty else { return [] }

        let taskDirectory = rootDirectory.appendingPathComponent(taskID.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: taskDirectory.path) else {
            throw AgentAttachmentError.duplicateTaskDirectory
        }

        do {
            try fileManager.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
            let encryptionKey = try keyProvider.loadOrCreateKey()
            var attachments: [AgentAttachment] = []

            for sourceFile in sourceFiles {
                let attachmentID = UUID()
                let safeFilename = Self.safeFilename(sourceFile.url.lastPathComponent)
                let destinationFilename = "\(attachmentID.uuidString)-\(safeFilename)"
                let destinationURL = taskDirectory.appendingPathComponent(destinationFilename, isDirectory: false)
                try copyEncryptedAttachment(
                    from: sourceFile.url,
                    expectedPlaintextByteCount: sourceFile.byteCount,
                    to: destinationURL,
                    using: encryptionKey
                )
                attachments.append(
                    AgentAttachment(
                        id: attachmentID,
                        originalFilename: sourceFile.url.lastPathComponent,
                        mediaType: Self.mediaType(for: sourceFile.url),
                        byteCount: sourceFile.byteCount,
                        storedRelativePath: "\(taskID.uuidString)/\(destinationFilename)"
                    )
                )
            }
            return attachments
        } catch let error as AgentAttachmentError {
            try? fileManager.removeItem(at: taskDirectory)
            throw error
        } catch {
            try? fileManager.removeItem(at: taskDirectory)
            throw AgentAttachmentError.copyFailed
        }
    }

    func chunk(for request: AgentAttachmentChunkRequest, in task: AgentTask) async throws -> AgentAttachmentChunk {
        guard request.offset >= 0,
              request.byteCount.map({ $0 >= 0 }) ?? true,
              let attachment = task.attachments.first(where: { $0.id == request.attachmentID }),
              request.offset <= attachment.byteCount else {
            throw AgentAttachmentError.invalidChunkRequest
        }

        let remainingByteCount = attachment.byteCount - request.offset
        let requestedByteCount = request.byteCount ?? remainingByteCount
        let plaintextByteCount = min(
            min(requestedByteCount, remainingByteCount),
            Self.maximumChunkByteCount
        )
        let requestedRangeEnd = request.offset + plaintextByteCount

        do {
            let attachmentURL = try resolvedAttachmentURL(for: attachment, taskID: task.id)
            let attributes = try fileManager.attributesOfItem(atPath: attachmentURL.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let containerByteCount = (attributes[.size] as? NSNumber)?.int64Value else {
                throw AgentAttachmentError.unreadableContainer
            }

            let handle = try FileHandle(forReadingFrom: attachmentURL)
            defer { try? handle.close() }

            let headerData = try readExactly(Self.encryptedContainerHeaderByteCount, from: handle)
            let header = try EncryptedAttachmentHeader(data: headerData)
            try header.validate(expectedPlaintextByteCount: attachment.byteCount)
            let expectedContainerByteCount = try header.expectedContainerByteCount()
            guard containerByteCount == expectedContainerByteCount else {
                throw AgentAttachmentError.unreadableContainer
            }
            try validateChunkLengths(in: handle, header: header)

            let encryptionKey = try keyProvider.loadOrCreateKey()
            let chunkIndices = chunkIndices(
                for: request.offset,
                plaintextByteCount: plaintextByteCount,
                header: header
            )
            var plaintextOutput = Data()
            plaintextOutput.reserveCapacity(Int(plaintextByteCount))

            do {
                for chunkIndex in chunkIndices {
                    let expectedProtectedByteCount = try header.protectedByteCount(for: chunkIndex)
                    let recordOffset = try header.recordOffset(for: chunkIndex)
                    try handle.seek(toOffset: UInt64(recordOffset))
                    _ = try readExactly(Self.encryptedChunkLengthByteCount, from: handle)
                    let protectedChunk = try readExactly(Int(expectedProtectedByteCount), from: handle)
                    let sealedBox = try AES.GCM.SealedBox(combined: protectedChunk)
                    let decryptedChunk = try AES.GCM.open(
                        sealedBox,
                        using: encryptionKey,
                        authenticating: header.authenticationData(for: chunkIndex)
                    )
                    let chunkPlaintextByteCount = try header.plaintextByteCount(for: chunkIndex)
                    guard decryptedChunk.count == Int(chunkPlaintextByteCount) else {
                        throw AgentAttachmentError.unreadableContainer
                    }

                    let chunkPlaintextOffset = Int64(chunkIndex) * header.plaintextChunkByteCount
                    let chunkPlaintextEnd = chunkPlaintextOffset + chunkPlaintextByteCount
                    let outputStart = max(request.offset, chunkPlaintextOffset)
                    let outputEnd = min(requestedRangeEnd, chunkPlaintextEnd)
                    if outputStart < outputEnd {
                        let lowerBound = Int(outputStart - chunkPlaintextOffset)
                        let upperBound = Int(outputEnd - chunkPlaintextOffset)
                        plaintextOutput.append(contentsOf: decryptedChunk[lowerBound..<upperBound])
                    }
                }

                guard plaintextOutput.count == Int(plaintextByteCount) else {
                    throw AgentAttachmentError.unreadableContainer
                }
            } catch {
                // A failed range read must not retain or return a partially decrypted value.
                plaintextOutput.removeAll(keepingCapacity: false)
                throw error
            }

            return AgentAttachmentChunk(
                attachmentID: attachment.id,
                offset: request.offset,
                content: plaintextOutput,
                isFinalChunk: requestedRangeEnd >= attachment.byteCount
            )
        } catch let error as AgentAttachmentError {
            throw error
        } catch {
            // CryptoKit intentionally gives no distinguishing signal for a modified
            // container versus a key that does not match the stored file.
            throw AgentAttachmentError.unreadableContainer
        }
    }

    func delete(_ attachments: [AgentAttachment]) async {
        let taskDirectories = Set(attachments.compactMap { attachment in
            try? validatedTaskDirectoryURL(for: attachment)
        })
        for taskDirectory in taskDirectories {
            try? fileManager.removeItem(at: taskDirectory)
        }
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("Macky", isDirectory: true)
            .appendingPathComponent("GeneralAgent", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    private func copyEncryptedAttachment(
        from sourceURL: URL,
        expectedPlaintextByteCount: Int64,
        to destinationURL: URL,
        using encryptionKey: SymmetricKey
    ) throws {
        let header = try EncryptedAttachmentHeader(plaintextByteCount: expectedPlaintextByteCount)
        let temporaryURL = destinationURL
            .deletingPathExtension()
            .appendingPathExtension("partial-\(UUID().uuidString)")
        let didAccessSecurityScopedURL = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedURL {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            try? fileManager.removeItem(at: temporaryURL)
        }

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw AgentAttachmentError.copyFailed
        }

        do {
            let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? sourceHandle.close() }
            let destinationHandle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? destinationHandle.close() }

            try destinationHandle.write(contentsOf: header.encoded())
            for chunkIndex in 0..<header.chunkCount {
                let chunkPlaintextByteCount = try header.plaintextByteCount(for: chunkIndex)
                let plaintextChunk = try readExactly(Int(chunkPlaintextByteCount), from: sourceHandle)
                let sealedBox = try AES.GCM.seal(
                    plaintextChunk,
                    using: encryptionKey,
                    authenticating: header.authenticationData(for: chunkIndex)
                )
                let expectedProtectedByteCount = try header.protectedByteCount(for: chunkIndex)
                guard let protectedChunk = sealedBox.combined,
                      protectedChunk.count == Int(expectedProtectedByteCount) else {
                    throw AgentAttachmentError.copyFailed
                }
                try destinationHandle.write(contentsOf: Self.data(for: UInt32(protectedChunk.count)))
                try destinationHandle.write(contentsOf: protectedChunk)
            }

            let trailingData = try sourceHandle.read(upToCount: 1) ?? Data()
            guard trailingData.isEmpty else {
                throw AgentAttachmentError.copyFailed
            }
            try destinationHandle.synchronize()
            try destinationHandle.close()
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw AgentAttachmentError.copyFailed
        }
    }

    private func validateChunkLengths(in handle: FileHandle, header: EncryptedAttachmentHeader) throws {
        for chunkIndex in 0..<header.chunkCount {
            let recordOffset = try header.recordOffset(for: chunkIndex)
            try handle.seek(toOffset: UInt64(recordOffset))
            let encodedLength = try readExactly(Self.encryptedChunkLengthByteCount, from: handle)
            let declaredProtectedByteCount = Self.uint32(from: encodedLength)
            let expectedProtectedByteCount = try header.protectedByteCount(for: chunkIndex)
            guard Int64(declaredProtectedByteCount) == expectedProtectedByteCount else {
                throw AgentAttachmentError.unreadableContainer
            }
        }
    }

    private func chunkIndices(
        for offset: Int64,
        plaintextByteCount: Int64,
        header: EncryptedAttachmentHeader
    ) -> [UInt32] {
        let firstChunkIndex = min(
            UInt32(offset / header.plaintextChunkByteCount),
            header.chunkCount - 1
        )
        guard plaintextByteCount > 0 else {
            // Even a zero-byte read authenticates the header with one nearby chunk.
            return [firstChunkIndex]
        }

        let lastChunkIndex = UInt32((offset + plaintextByteCount - 1) / header.plaintextChunkByteCount)
        return Array(firstChunkIndex...lastChunkIndex)
    }

    private func resolvedAttachmentURL(for attachment: AgentAttachment, taskID: UUID) throws -> URL {
        let components = try validatedPathComponents(for: attachment)
        guard UUID(uuidString: components.taskDirectoryName) == taskID else {
            throw AgentAttachmentError.invalidStoredPath
        }
        return try containedURL(
            taskDirectoryName: components.taskDirectoryName,
            filename: components.filename
        )
    }

    private func validatedTaskDirectoryURL(for attachment: AgentAttachment) throws -> URL {
        let components = try validatedPathComponents(for: attachment)
        return try containedURL(
            taskDirectoryName: components.taskDirectoryName,
            filename: components.filename
        ).deletingLastPathComponent()
    }

    private func validatedPathComponents(for attachment: AgentAttachment) throws -> (
        taskDirectoryName: String,
        filename: String
    ) {
        let components = attachment.storedRelativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let taskDirectoryName = components.first.map(String.init),
              let filename = components.last.map(String.init),
              UUID(uuidString: taskDirectoryName) != nil,
              !filename.isEmpty,
              filename != ".",
              filename != ".." else {
            throw AgentAttachmentError.invalidStoredPath
        }
        return (taskDirectoryName, filename)
    }

    private func containedURL(taskDirectoryName: String, filename: String) throws -> URL {
        let rootURL = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidateURL = rootDirectory
            .appendingPathComponent(taskDirectoryName, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidateURL.path.hasPrefix(rootPath) else {
            throw AgentAttachmentError.invalidStoredPath
        }
        return candidateURL
    }

    private func readExactly(_ byteCount: Int, from handle: FileHandle) throws -> Data {
        guard byteCount >= 0 else {
            throw AgentAttachmentError.unreadableContainer
        }
        guard byteCount > 0 else {
            return Data()
        }
        guard
              let data = try handle.read(upToCount: byteCount),
              data.count == byteCount else {
            throw AgentAttachmentError.unreadableContainer
        }
        return data
    }

    private static func safeFilename(_ filename: String) -> String {
        let normalized = URL(fileURLWithPath: filename).lastPathComponent
        return normalized.isEmpty ? "attachment" : normalized
    }

    private static func mediaType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "csv", "json", "swift", "ts", "js", "py":
            return "text/plain"
        case "pdf":
            return "application/pdf"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        default:
            return nil
        }
    }

    private static func data(for value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func data(for value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func uint32(from data: Data) -> UInt32 {
        data.reduce(0) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }

    private static func uint64(from data: Data) -> UInt64 {
        data.reduce(0) { partialResult, byte in
            (partialResult << 8) | UInt64(byte)
        }
    }

    private struct EncryptedAttachmentHeader {
        let plaintextByteCount: Int64
        let plaintextChunkByteCount: Int64
        let chunkCount: UInt32
        let containerIdentifier: Data

        init(plaintextByteCount: Int64) throws {
            guard (0...AgentAttachmentStore.maximumTotalBytes).contains(plaintextByteCount) else {
                throw AgentAttachmentError.copyFailed
            }
            self.plaintextByteCount = plaintextByteCount
            self.plaintextChunkByteCount = AgentAttachmentStore.plaintextContainerChunkByteCount
            self.chunkCount = try Self.expectedChunkCount(
                plaintextByteCount: plaintextByteCount,
                chunkByteCount: AgentAttachmentStore.plaintextContainerChunkByteCount
            )
            self.containerIdentifier = Self.randomContainerIdentifier()
        }

        init(data: Data) throws {
            guard data.count == AgentAttachmentStore.encryptedContainerHeaderByteCount,
                  data.prefix(AgentAttachmentStore.containerMagic.count) == AgentAttachmentStore.containerMagic else {
                throw AgentAttachmentError.unreadableContainer
            }
            let versionOffset = AgentAttachmentStore.containerMagic.count
            guard data[versionOffset] == AgentAttachmentStore.containerVersion else {
                throw AgentAttachmentError.unreadableContainer
            }

            let originalByteCountOffset = versionOffset + 1
            let chunkByteCountOffset = originalByteCountOffset + 8
            let chunkCountOffset = chunkByteCountOffset + 4
            let identifierOffset = chunkCountOffset + 4
            let originalByteCount = AgentAttachmentStore.uint64(
                from: Data(data[originalByteCountOffset..<(originalByteCountOffset + 8)])
            )
            guard originalByteCount <= UInt64(Int64.max) else {
                throw AgentAttachmentError.unreadableContainer
            }

            self.plaintextByteCount = Int64(originalByteCount)
            self.plaintextChunkByteCount = Int64(AgentAttachmentStore.uint32(
                from: Data(data[chunkByteCountOffset..<(chunkByteCountOffset + 4)])
            ))
            self.chunkCount = AgentAttachmentStore.uint32(
                from: Data(data[chunkCountOffset..<(chunkCountOffset + 4)])
            )
            self.containerIdentifier = Data(data[identifierOffset..<data.endIndex])
        }

        func validate(expectedPlaintextByteCount: Int64) throws {
            let expectedChunkCount = try Self.expectedChunkCount(
                plaintextByteCount: plaintextByteCount,
                chunkByteCount: plaintextChunkByteCount
            )
            guard plaintextByteCount == expectedPlaintextByteCount,
                  (0...AgentAttachmentStore.maximumTotalBytes).contains(plaintextByteCount),
                  plaintextChunkByteCount == AgentAttachmentStore.plaintextContainerChunkByteCount,
                  containerIdentifier.count == 16,
                  chunkCount == expectedChunkCount else {
                throw AgentAttachmentError.unreadableContainer
            }
        }

        func encoded() -> Data {
            var data = AgentAttachmentStore.containerMagic
            data.append(AgentAttachmentStore.containerVersion)
            data.append(AgentAttachmentStore.data(for: UInt64(plaintextByteCount)))
            data.append(AgentAttachmentStore.data(for: UInt32(plaintextChunkByteCount)))
            data.append(AgentAttachmentStore.data(for: chunkCount))
            data.append(containerIdentifier)
            return data
        }

        func authenticationData(for chunkIndex: UInt32) -> Data {
            var data = encoded()
            data.append(AgentAttachmentStore.data(for: chunkIndex))
            return data
        }

        func plaintextByteCount(for chunkIndex: UInt32) throws -> Int64 {
            guard chunkIndex < chunkCount else {
                throw AgentAttachmentError.unreadableContainer
            }
            let chunkOffset = Int64(chunkIndex) * plaintextChunkByteCount
            return min(plaintextChunkByteCount, plaintextByteCount - chunkOffset)
        }

        func protectedByteCount(for chunkIndex: UInt32) throws -> Int64 {
            plaintextByteCount(for: chunkIndex) + AgentAttachmentStore.encryptedChunkCombinedOverheadByteCount
        }

        func recordOffset(for chunkIndex: UInt32) throws -> Int64 {
            guard chunkIndex < chunkCount else {
                throw AgentAttachmentError.unreadableContainer
            }
            let fullChunkRecordByteCount = AgentAttachmentStore.encryptedChunkLengthByteCount
                + plaintextChunkByteCount
                + AgentAttachmentStore.encryptedChunkCombinedOverheadByteCount
            return Int64(AgentAttachmentStore.encryptedContainerHeaderByteCount)
                + Int64(chunkIndex) * fullChunkRecordByteCount
        }

        func expectedContainerByteCount() throws -> Int64 {
            let encryptedChunkOverhead = Int64(chunkCount)
                * (Int64(AgentAttachmentStore.encryptedChunkLengthByteCount)
                   + AgentAttachmentStore.encryptedChunkCombinedOverheadByteCount)
            return Int64(AgentAttachmentStore.encryptedContainerHeaderByteCount)
                + plaintextByteCount
                + encryptedChunkOverhead
        }

        private static func expectedChunkCount(
            plaintextByteCount: Int64,
            chunkByteCount: Int64
        ) throws -> UInt32 {
            guard plaintextByteCount >= 0, chunkByteCount > 0 else {
                throw AgentAttachmentError.unreadableContainer
            }
            let calculatedChunkCount = max(
                Int64(1),
                (plaintextByteCount + chunkByteCount - 1) / chunkByteCount
            )
            guard calculatedChunkCount <= Int64(UInt32.max) else {
                throw AgentAttachmentError.unreadableContainer
            }
            return UInt32(calculatedChunkCount)
        }

        private static func randomContainerIdentifier() -> Data {
            var uuid = UUID().uuid
            return withUnsafeBytes(of: &uuid) { Data($0) }
        }
    }
}

enum AgentAttachmentError: LocalizedError, Equatable {
    case tooManyFiles(limit: Int)
    case totalSizeExceeded(limit: Int64)
    case notAFile(String)
    case duplicateTaskDirectory
    case copyFailed
    case invalidChunkRequest
    case invalidStoredPath
    case unreadableContainer

    var errorDescription: String? {
        switch self {
        case .tooManyFiles(let limit):
            return "A General Agent task can include at most \(limit) copied attachments."
        case .totalSizeExceeded(let limit):
            return "Copied attachments may total at most \(limit / (1024 * 1024)) MB."
        case .notAFile(let name):
            return "\(name) is not a regular file."
        case .duplicateTaskDirectory:
            return "Attachments have already been copied for this task."
        case .copyFailed:
            return "The attachment could not be copied into encrypted General Agent storage."
        case .invalidChunkRequest:
            return "The requested attachment chunk is invalid."
        case .invalidStoredPath:
            return "The stored attachment path is invalid."
        case .unreadableContainer:
            return "The encrypted attachment is unreadable or has been modified."
        }
    }
}
