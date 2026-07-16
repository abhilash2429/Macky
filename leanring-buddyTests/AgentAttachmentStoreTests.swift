import CryptoKit
import Foundation
import XCTest
@testable import Macky

final class AgentAttachmentStoreTests: XCTestCase {
    private let oneMiB = 1_048_576

    func testStoresCiphertextWhileServingCopiedPlaintext() async throws {
        let plaintext = Data("Macky attachment plaintext must never appear in its copied container.".utf8)
        let fixture = try await makeFixture(plaintext: plaintext)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        let storedContainer = try Data(contentsOf: fixture.storedContainerURL)
        XCTAssertEqual(fixture.attachment.byteCount, Int64(plaintext.count))
        XCTAssertNil(storedContainer.range(of: plaintext))

        try Data("changed source".utf8).write(to: fixture.sourceURL)
        let chunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: 0,
                byteCount: Int64(plaintext.count)
            ),
            in: fixture.task
        )

        XCTAssertEqual(chunk.content, plaintext)
        XCTAssertTrue(chunk.isFinalChunk)
    }

    func testSupportsBoundaryCrossChunkRepeatedAndFinalReads() async throws {
        let chunkByteCount = Int(AgentAttachmentStore.plaintextContainerChunkByteCount)
        let plaintext = deterministicData(byteCount: chunkByteCount * 2 + 37)
        let fixture = try await makeFixture(plaintext: plaintext)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        let boundaryChunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: Int64(chunkByteCount),
                byteCount: 32
            ),
            in: fixture.task
        )
        XCTAssertEqual(boundaryChunk.content, dataSlice(plaintext, offset: chunkByteCount, byteCount: 32))
        XCTAssertFalse(boundaryChunk.isFinalChunk)

        let crossBoundaryOffset = chunkByteCount - 5
        let crossBoundaryChunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: Int64(crossBoundaryOffset),
                byteCount: 17
            ),
            in: fixture.task
        )
        XCTAssertEqual(crossBoundaryChunk.content, dataSlice(plaintext, offset: crossBoundaryOffset, byteCount: 17))
        XCTAssertFalse(crossBoundaryChunk.isFinalChunk)

        let repeatedRead = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: Int64(crossBoundaryOffset),
                byteCount: 17
            ),
            in: fixture.task
        )
        XCTAssertEqual(repeatedRead, crossBoundaryChunk)

        let finalChunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: Int64(plaintext.count - 37),
                byteCount: nil
            ),
            in: fixture.task
        )
        XCTAssertEqual(finalChunk.content, dataSlice(plaintext, offset: plaintext.count - 37, byteCount: 37))
        XCTAssertTrue(finalChunk.isFinalChunk)
    }

    func testNilAndOversizedByteCountsAreCappedAtOneMiB() async throws {
        let plaintext = deterministicData(byteCount: oneMiB + 1)
        let fixture = try await makeFixture(plaintext: plaintext)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        let nilByteCountChunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: 0,
                byteCount: nil
            ),
            in: fixture.task
        )
        XCTAssertEqual(nilByteCountChunk.content.count, oneMiB)
        XCTAssertFalse(nilByteCountChunk.isFinalChunk)

        let oversizedByteCountChunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: 0,
                byteCount: Int64(oneMiB) + 1
            ),
            in: fixture.task
        )
        XCTAssertEqual(oversizedByteCountChunk.content, nilByteCountChunk.content)
        XCTAssertFalse(oversizedByteCountChunk.isFinalChunk)
    }

    func testExactOneMiBBoundaryIsFinal() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: oneMiB))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        let chunk = try await fixture.store.chunk(
            for: AgentAttachmentChunkRequest(
                attachmentID: fixture.attachment.id,
                offset: 0,
                byteCount: Int64(oneMiB)
            ),
            in: fixture.task
        )

        XCTAssertEqual(chunk.content.count, oneMiB)
        XCTAssertTrue(chunk.isFinalChunk)
    }

    func testRejectsInvalidOffsetsAndCounts() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 8))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        let invalidRequests = [
            AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: -1),
            AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: 0, byteCount: -1),
            AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: 9)
        ]

        for request in invalidRequests {
            do {
                _ = try await fixture.store.chunk(for: request, in: fixture.task)
                XCTFail("Expected an invalid chunk request to be rejected")
            } catch let error as AgentAttachmentError {
                XCTAssertEqual(error, .invalidChunkRequest)
            }
        }
    }

    func testRejectsMoreThanTenAttachments() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.txt")
        try Data("x".utf8).write(to: sourceURL)
        let store = AgentAttachmentStore(
            rootDirectory: temporaryDirectory.appendingPathComponent("copied"),
            keyProvider: DeterministicAttachmentKeyProvider(byte: 0x01)
        )

        do {
            _ = try await store.copyAttachments(from: Array(repeating: sourceURL, count: 11), for: UUID())
            XCTFail("Expected the attachment limit to reject eleven files")
        } catch let error as AgentAttachmentError {
            XCTAssertEqual(error, .tooManyFiles(limit: AgentAttachmentStore.maximumAttachmentCount))
        }
    }

    func testRejectsAttachmentsLargerThanFiftyMiB() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("large.bin")
        _ = FileManager.default.createFile(atPath: sourceURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: sourceURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(AgentAttachmentStore.maximumTotalBytes))
            try handle.write(contentsOf: Data([0x01]))
            try handle.synchronize()
        }

        let store = AgentAttachmentStore(
            rootDirectory: temporaryDirectory.appendingPathComponent("copied"),
            keyProvider: DeterministicAttachmentKeyProvider(byte: 0x01)
        )
        do {
            _ = try await store.copyAttachments(from: [sourceURL], for: UUID())
            XCTFail("Expected the total attachment limit to reject a 50 MiB-plus file")
        } catch let error as AgentAttachmentError {
            XCTAssertEqual(error, .totalSizeExceeded(limit: AgentAttachmentStore.maximumTotalBytes))
        }
    }

    func testRejectsWrongKey() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 128))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }
        let wrongKeyStore = AgentAttachmentStore(
            rootDirectory: fixture.rootDirectory,
            keyProvider: DeterministicAttachmentKeyProvider(byte: 0x02)
        )

        await assertUnreadableContainer {
            _ = try await wrongKeyStore.chunk(
                for: AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: 0, byteCount: 16),
                in: fixture.task
            )
        }
    }

    func testRejectsCorruptedCiphertextWithoutReturningPartialPlaintext() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 128))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        var containerData = try Data(contentsOf: fixture.storedContainerURL)
        let firstCiphertextByteOffset = AgentAttachmentStore.encryptedContainerHeaderByteCount
            + AgentAttachmentStore.encryptedChunkLengthByteCount
        containerData[firstCiphertextByteOffset] = containerData[firstCiphertextByteOffset] ^ 0xFF
        try containerData.write(to: fixture.storedContainerURL)

        await assertUnreadableContainer {
            _ = try await fixture.store.chunk(
                for: AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: 0, byteCount: 16),
                in: fixture.task
            )
        }
    }

    func testRejectsTruncatedContainerBeforeServingAChunk() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 128))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        let containerData = try Data(contentsOf: fixture.storedContainerURL)
        try Data(containerData.dropLast()).write(to: fixture.storedContainerURL)

        await assertUnreadableContainer {
            _ = try await fixture.store.chunk(
                for: AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: 0, byteCount: 16),
                in: fixture.task
            )
        }
    }

    func testRejectsCorruptedChunkLengthAndMismatchedPlaintextSize() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 128))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }

        var malformedLengthData = try Data(contentsOf: fixture.storedContainerURL)
        let chunkLengthOffset = AgentAttachmentStore.encryptedContainerHeaderByteCount
        malformedLengthData[chunkLengthOffset] = malformedLengthData[chunkLengthOffset] ^ 0x01
        try malformedLengthData.write(to: fixture.storedContainerURL)
        await assertUnreadableContainer {
            _ = try await fixture.store.chunk(
                for: AgentAttachmentChunkRequest(attachmentID: fixture.attachment.id, offset: 0, byteCount: 16),
                in: fixture.task
            )
        }

        let intactFixture = try await makeFixture(plaintext: deterministicData(byteCount: 128))
        defer { try? FileManager.default.removeItem(at: intactFixture.temporaryDirectory) }
        let sizeMismatchAttachment = AgentAttachment(
            id: intactFixture.attachment.id,
            originalFilename: intactFixture.attachment.originalFilename,
            mediaType: intactFixture.attachment.mediaType,
            byteCount: intactFixture.attachment.byteCount + 1,
            storedRelativePath: intactFixture.attachment.storedRelativePath,
            copiedAt: intactFixture.attachment.copiedAt
        )
        let sizeMismatchTask = task(for: sizeMismatchAttachment, taskID: intactFixture.task.id)
        await assertUnreadableContainer {
            _ = try await intactFixture.store.chunk(
                for: AgentAttachmentChunkRequest(attachmentID: sizeMismatchAttachment.id, offset: 0, byteCount: 16),
                in: sizeMismatchTask
            )
        }
    }

    func testRejectsStoredPathsOutsideTheAttachmentRoot() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 64))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }
        let invalidAttachment = AgentAttachment(
            id: fixture.attachment.id,
            originalFilename: fixture.attachment.originalFilename,
            mediaType: fixture.attachment.mediaType,
            byteCount: fixture.attachment.byteCount,
            storedRelativePath: "../source.bin",
            copiedAt: fixture.attachment.copiedAt
        )
        let invalidTask = task(for: invalidAttachment, taskID: fixture.task.id)

        do {
            _ = try await fixture.store.chunk(
                for: AgentAttachmentChunkRequest(attachmentID: invalidAttachment.id, offset: 0, byteCount: 16),
                in: invalidTask
            )
            XCTFail("Expected a path outside the attachment root to be rejected")
        } catch let error as AgentAttachmentError {
            XCTAssertEqual(error, .invalidStoredPath)
        }
    }

    func testDeleteRemovesEncryptedContainerDirectory() async throws {
        let fixture = try await makeFixture(plaintext: deterministicData(byteCount: 64))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryDirectory) }
        let taskDirectory = fixture.storedContainerURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectory.path))

        await fixture.store.delete([fixture.attachment])

        XCTAssertFalse(FileManager.default.fileExists(atPath: taskDirectory.path))
    }

    func testCopyFailureRemovesPartialContainerOutput() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.bin")
        try deterministicData(byteCount: 128).write(to: sourceURL)
        let rootDirectory = temporaryDirectory.appendingPathComponent("copied")
        let taskID = UUID()
        let store = AgentAttachmentStore(
            rootDirectory: rootDirectory,
            keyProvider: FailingAttachmentKeyProvider()
        )

        do {
            _ = try await store.copyAttachments(from: [sourceURL], for: taskID)
            XCTFail("Expected encryption-key failure to abort the copy")
        } catch let error as AgentAttachmentError {
            XCTAssertEqual(error, .copyFailed)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootDirectory.appendingPathComponent(taskID.uuidString).path
            )
        )
    }

    private struct AttachmentFixture {
        let temporaryDirectory: URL
        let rootDirectory: URL
        let sourceURL: URL
        let store: AgentAttachmentStore
        let task: AgentTask
        let attachment: AgentAttachment

        var storedContainerURL: URL {
            rootDirectory.appendingPathComponent(attachment.storedRelativePath)
        }
    }

    private struct DeterministicAttachmentKeyProvider: AgentEncryptionKeyProviding {
        let keyData: Data

        init(byte: UInt8) {
            keyData = Data(repeating: byte, count: 32)
        }

        func loadOrCreateKey() throws -> SymmetricKey {
            SymmetricKey(data: keyData)
        }
    }

    private struct FailingAttachmentKeyProvider: AgentEncryptionKeyProviding {
        func loadOrCreateKey() throws -> SymmetricKey {
            throw AttachmentKeyProviderFailure.failed
        }
    }

    private enum AttachmentKeyProviderFailure: Error {
        case failed
    }

    private func makeFixture(plaintext: Data) async throws -> AttachmentFixture {
        let temporaryDirectory = try makeTemporaryDirectory()
        let rootDirectory = temporaryDirectory.appendingPathComponent("copied", isDirectory: true)
        let sourceURL = temporaryDirectory.appendingPathComponent("source.bin")
        try plaintext.write(to: sourceURL)

        let store = AgentAttachmentStore(
            rootDirectory: rootDirectory,
            keyProvider: DeterministicAttachmentKeyProvider(byte: 0x01)
        )
        let taskID = UUID()
        let attachments = try await store.copyAttachments(from: [sourceURL], for: taskID)
        let attachment = try XCTUnwrap(attachments.first)

        return AttachmentFixture(
            temporaryDirectory: temporaryDirectory,
            rootDirectory: rootDirectory,
            sourceURL: sourceURL,
            store: store,
            task: task(for: attachment, taskID: taskID),
            attachment: attachment
        )
    }

    private func task(for attachment: AgentAttachment, taskID: UUID) -> AgentTask {
        AgentTask(
            id: taskID,
            agentID: AgentRegistry.general.id,
            instruction: "Read the attachment",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: [attachment]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        return temporaryDirectory
    }

    private func deterministicData(byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 * 31 + 17) })
    }

    private func dataSlice(_ data: Data, offset: Int, byteCount: Int) -> Data {
        Data(data[offset..<(offset + byteCount)])
    }

    private func assertUnreadableContainer(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected the encrypted container to be unreadable", file: file, line: line)
        } catch let error as AgentAttachmentError {
            XCTAssertEqual(error, .unreadableContainer, file: file, line: line)
        } catch {
            XCTFail("Expected AgentAttachmentError.unreadableContainer, received \(error)", file: file, line: line)
        }
    }
}
