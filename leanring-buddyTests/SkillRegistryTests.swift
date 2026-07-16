import CryptoKit
import XCTest
@testable import Macky

final class SkillRegistryTests: XCTestCase {
    private let userDefinitionsDefaultsKey = "mackySkillDefinitionsV1"

    func testBuiltInsKeepStableIdsAndCannotBeSavedAsUserSkills() {
        let builtInIDs = SkillRegistry.builtInSkills.map(\.id)
        XCTAssertEqual(
            builtInIDs,
            [
                "meeting-assistant",
                "email-assistant",
                "research",
                "code-review",
                "team-updates",
                "music-control"
            ]
        )

        let defaults = makeDefaults()
        let builtIn = try! XCTUnwrap(SkillRegistry.builtInSkills.first { $0.id == "research" })
        XCTAssertThrowsError(try SkillRegistry.saveUserSkill(builtIn, defaults: defaults)) { error in
            XCTAssertEqual(error as? SkillPersistenceError, .cannotModifyBuiltIn)
        }
    }

    func testUserSkillRoundTripsLocallyWithHashAndCompactMetadata() throws {
        let defaults = makeDefaults()
        let keyProvider = DeterministicSkillKeyProvider(byte: 0x21)
        let draft = SkillDraft(
            name: "Release Notes",
            description: "Turns merged changes into a concise release summary.",
            instructions: "Group changes by user impact, call out breaking changes, and keep the final summary under ten bullets.",
            compatibleAgentTypes: ["assistant", "writer"],
            origin: .manual
        )
        let skill = SkillDefinition.makeUserSkill(
            from: draft,
            id: "user-release-notes",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        try SkillRegistry.saveUserSkill(skill, defaults: defaults, keyProvider: keyProvider)

        let storedData = try XCTUnwrap(defaults.data(forKey: userDefinitionsDefaultsKey))
        let plaintext = try encodeDefinitions([skill])
        XCTAssertNotEqual(storedData, plaintext)
        XCTAssertNil(try? JSONDecoder().decode([SkillDefinition].self, from: storedData))
        XCTAssertEqual(try decryptDefinitions(storedData, with: keyProvider), [skill])

        let loaded = try XCTUnwrap(
            SkillRegistry.userSkillDefinitions(defaults: defaults, keyProvider: keyProvider).first
        )
        XCTAssertEqual(loaded, skill)
        XCTAssertEqual(loaded.contentHash.count, 64)
        XCTAssertEqual(loaded.compactMetadata.name, skill.name)
        XCTAssertEqual(loaded.compactMetadata.description, skill.description)
        XCTAssertFalse(loaded.compactMetadata.contentHash.isEmpty)

        XCTAssertThrowsError(
            try SkillRegistry.saveUserSkill(skill, defaults: defaults, keyProvider: keyProvider)
        ) { error in
            XCTAssertEqual(error as? SkillPersistenceError, .duplicateID)
        }
        XCTAssertEqual(
            SkillRegistry.userSkillDefinitions(defaults: defaults, keyProvider: keyProvider),
            [skill]
        )
    }

    func testLegacyPlaintextSkillDefinitionsMigrateAfterExistingFiltering() throws {
        let defaults = makeDefaults()
        let keyProvider = DeterministicSkillKeyProvider(byte: 0x32)
        let firstSkill = makeSkill(id: "user-first", createdAt: Date(timeIntervalSince1970: 3))
        let duplicateSkill = makeSkill(id: firstSkill.id, createdAt: Date(timeIntervalSince1970: 1))
        let secondSkill = makeSkill(id: "user-second", createdAt: Date(timeIntervalSince1970: 2))
        let legacyDefinitions = [
            SkillRegistry.builtInSkills[0],
            firstSkill,
            duplicateSkill,
            secondSkill
        ]
        let legacyData = try encodeDefinitions(legacyDefinitions)
        defaults.set(legacyData, forKey: userDefinitionsDefaultsKey)

        let loaded = SkillRegistry.userSkillDefinitions(
            defaults: defaults,
            keyProvider: keyProvider
        )

        XCTAssertEqual(loaded, [secondSkill, firstSkill])
        let migratedData = try XCTUnwrap(defaults.data(forKey: userDefinitionsDefaultsKey))
        XCTAssertNotEqual(migratedData, legacyData)
        XCTAssertEqual(try decryptDefinitions(migratedData, with: keyProvider), [secondSkill, firstSkill])
        XCTAssertEqual(
            SkillRegistry.userSkillDefinitions(defaults: defaults, keyProvider: keyProvider),
            [secondSkill, firstSkill]
        )
    }

    func testWrongKeyFailsClosedWithoutOverwritingCiphertext() throws {
        let defaults = makeDefaults()
        let savingKeyProvider = DeterministicSkillKeyProvider(byte: 0x43)
        let wrongKeyProvider = DeterministicSkillKeyProvider(byte: 0x44)
        let skill = makeSkill(id: "user-wrong-key")

        try SkillRegistry.saveUserSkill(
            skill,
            defaults: defaults,
            keyProvider: savingKeyProvider
        )
        let originalData = try XCTUnwrap(defaults.data(forKey: userDefinitionsDefaultsKey))

        XCTAssertTrue(
            SkillRegistry.userSkillDefinitions(
                defaults: defaults,
                keyProvider: wrongKeyProvider
            ).isEmpty
        )
        XCTAssertEqual(defaults.data(forKey: userDefinitionsDefaultsKey), originalData)
    }

    func testCorruptedCiphertextFailsClosedWithoutOverwritingOrReplacingIt() throws {
        let defaults = makeDefaults()
        let keyProvider = DeterministicSkillKeyProvider(byte: 0x55)
        let skill = makeSkill(id: "user-corrupted")

        try SkillRegistry.saveUserSkill(skill, defaults: defaults, keyProvider: keyProvider)
        var corruptedData = try XCTUnwrap(defaults.data(forKey: userDefinitionsDefaultsKey))
        corruptedData[0] ^= 0xFF
        defaults.set(corruptedData, forKey: userDefinitionsDefaultsKey)

        XCTAssertTrue(
            SkillRegistry.userSkillDefinitions(
                defaults: defaults,
                keyProvider: keyProvider
            ).isEmpty
        )
        XCTAssertEqual(defaults.data(forKey: userDefinitionsDefaultsKey), corruptedData)
        XCTAssertThrowsError(
            try SkillRegistry.saveUserSkill(
                skill,
                defaults: defaults,
                keyProvider: keyProvider
            )
        ) { error in
            XCTAssertEqual(error as? SkillPersistenceError, .unreadableData)
        }
        XCTAssertEqual(defaults.data(forKey: userDefinitionsDefaultsKey), corruptedData)
    }

    func testDeletingUserSkillDoesNotAffectBuiltIns() throws {
        let defaults = makeDefaults()
        let keyProvider = DeterministicSkillKeyProvider(byte: 0x66)
        let skill = makeSkill(id: "user-daily-brief", createdAt: Date(timeIntervalSince1970: 1))
        let retainedSkill = makeSkill(id: "user-retained", createdAt: Date(timeIntervalSince1970: 2))
        try SkillRegistry.saveUserSkill(skill, defaults: defaults, keyProvider: keyProvider)
        try SkillRegistry.saveUserSkill(retainedSkill, defaults: defaults, keyProvider: keyProvider)

        try SkillRegistry.deleteUserSkill(
            withID: skill.id,
            defaults: defaults,
            keyProvider: keyProvider
        )

        XCTAssertEqual(
            SkillRegistry.userSkillDefinitions(defaults: defaults, keyProvider: keyProvider),
            [retainedSkill]
        )
        XCTAssertNotNil(SkillRegistry.builtInSkills.first { $0.id == "research" })
    }

    func testEnabledSkillIDMigrationPreservesLegacyKeyAndRemovesMalformedValues() {
        let defaults = makeDefaults()
        defaults.set(["meeting-assistant", " user-defined ", 42, ""], forKey: SkillRegistry.enabledSkillIDsDefaultsKey)

        SkillRegistry.migrateEnabledSkillIDs(defaults: defaults)

        XCTAssertEqual(
            defaults.stringArray(forKey: SkillRegistry.enabledSkillIDsDefaultsKey),
            ["meeting-assistant", "user-defined"]
        )
    }

    func testDraftValidationRequiresReusableSkillFields() {
        XCTAssertNotNil(SkillDraft().validationError)

        let completeDraft = SkillDraft(
            name: "Focus Mode",
            description: "Keeps work sessions distraction-free.",
            instructions: "Mute distractions and keep the user focused on the stated task.",
            compatibleAgentTypes: ["operator"]
        )
        XCTAssertNil(completeDraft.validationError)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SkillRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSkill(
        id: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> SkillDefinition {
        SkillDefinition.makeUserSkill(
            from: SkillDraft(
                name: "Skill \(id)",
                description: "A reusable test Skill.",
                instructions: "Apply the reusable test instructions for \(id).",
                compatibleAgentTypes: ["assistant"]
            ),
            id: id,
            createdAt: createdAt
        )
    }

    private func encodeDefinitions(_ definitions: [SkillDefinition]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(definitions)
    }

    private func decryptDefinitions(
        _ encryptedData: Data,
        with keyProvider: DeterministicSkillKeyProvider
    ) throws -> [SkillDefinition] {
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let plaintext = try AES.GCM.open(sealedBox, using: keyProvider.loadOrCreateKey())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([SkillDefinition].self, from: plaintext)
    }
}

private struct DeterministicSkillKeyProvider: AgentEncryptionKeyProviding {
    private let keyData: Data

    init(byte: UInt8) {
        self.keyData = Data(repeating: byte, count: 32)
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: keyData)
    }
}
