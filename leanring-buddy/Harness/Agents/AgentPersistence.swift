//
//  AgentPersistence.swift
//  leanring-buddy
//

import CryptoKit
import Foundation
import Security

protocol AgentEncryptionKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

/// Stores the AES key in the user's Keychain. The encrypted state file is therefore
/// useless if it is copied without the matching local Keychain item.
struct AgentKeychainKeyProvider: AgentEncryptionKeyProviding {
    private static let service = "macky.general-agent.persistence"
    private static let account = "state-encryption-key"
    private static let keyByteCount = 32

    func loadOrCreateKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if readStatus == errSecSuccess, let existingData = result as? Data {
            guard existingData.count == Self.keyByteCount else {
                throw AgentPersistenceError.invalidKeychainKey
            }
            return SymmetricKey(data: existingData)
        }

        guard readStatus == errSecItemNotFound else {
            throw AgentPersistenceError.keychainFailure(readStatus)
        }

        var bytes = [UInt8](repeating: 0, count: Self.keyByteCount)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw AgentPersistenceError.keyGenerationFailed
        }
        let newKeyData = Data(bytes)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: newKeyData
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AgentPersistenceError.keychainFailure(addStatus)
        }
        return SymmetricKey(data: newKeyData)
    }
}

/// File-backed local persistence for task state. This object never contacts the
/// Worker; all state is JSON-encoded then AES-GCM encrypted before it touches disk.
actor AgentEncryptedPersistence: AgentStatePersisting {
    private let fileURL: URL
    private let keyProvider: AgentEncryptionKeyProviding
    private let fileManager: FileManager

    init(
        fileURL: URL = AgentEncryptedPersistence.defaultFileURL(),
        keyProvider: AgentEncryptionKeyProviding = AgentKeychainKeyProvider(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    func load() async throws -> AgentPersistentState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        do {
            let encryptedData = try Data(contentsOf: fileURL)
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let plaintext = try AES.GCM.open(sealedBox, using: keyProvider.loadOrCreateKey())
            return try JSONDecoder().decode(AgentPersistentState.self, from: plaintext)
        } catch let error as AgentPersistenceError {
            throw error
        } catch {
            throw AgentPersistenceError.unreadableState
        }
    }

    func save(_ state: AgentPersistentState) async throws {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let plaintext = try JSONEncoder().encode(state)
            let sealedBox = try AES.GCM.seal(plaintext, using: keyProvider.loadOrCreateKey())
            guard let encryptedData = sealedBox.combined else {
                throw AgentPersistenceError.encryptionFailed
            }
            try encryptedData.write(to: fileURL, options: .atomic)
        } catch let error as AgentPersistenceError {
            throw error
        } catch {
            throw AgentPersistenceError.writeFailed
        }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("Macky", isDirectory: true)
            .appendingPathComponent("GeneralAgent", isDirectory: true)
            .appendingPathComponent("state.bin", isDirectory: false)
    }
}

/// A simple injected store for previews and unit tests. It is deliberately an actor
/// so its behavior matches the production persistence boundary.
actor AgentInMemoryPersistence: AgentStatePersisting {
    private var state: AgentPersistentState

    init(initialState: AgentPersistentState = .empty) {
        self.state = initialState
    }

    func load() async throws -> AgentPersistentState {
        state
    }

    func save(_ state: AgentPersistentState) async throws {
        self.state = state
    }
}

enum AgentPersistenceError: LocalizedError, Equatable {
    case invalidKeychainKey
    case keychainFailure(OSStatus)
    case keyGenerationFailed
    case encryptionFailed
    case unreadableState
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeychainKey:
            return "The local General Agent encryption key is invalid."
        case .keychainFailure(let status):
            return "The local General Agent Keychain operation failed (\(status))."
        case .keyGenerationFailed:
            return "The local General Agent encryption key could not be generated."
        case .encryptionFailed:
            return "The local General Agent state could not be encrypted."
        case .unreadableState:
            return "The local General Agent state could not be read."
        case .writeFailed:
            return "The local General Agent state could not be saved."
        }
    }
}
