//
//  SkillRegistry.swift
//  leanring-buddy
//
//  The client-side catalog for Macky's reusable Skills. Skills are instruction
//  bundles, not agents: they describe a capability that can be made available
//  to a compatible agent in a later realtime-session milestone.
//
//  Built-ins are source-defined and immutable. User Skills are stored locally
//  as encrypted JSON in UserDefaults and are immutable after saving; revising one means
//  creating a duplicate draft with a new id.
//

import CryptoKit
import Foundation

enum SkillOrigin: String, Codable, CaseIterable, Equatable {
    case builtIn = "built-in"
    case manual
    case aiDraft = "ai-draft"
    case duplicate

    var displayName: String {
        switch self {
        case .builtIn:
            return "Built-in"
        case .manual:
            return "Manual"
        case .aiDraft:
            return "AI draft"
        case .duplicate:
            return "Duplicate"
        }
    }
}

/// The small metadata shape that can be attached to a future realtime request
/// without sending the full instruction body. Instructions remain on the full
/// definition so that the realtime wiring milestone can choose when to include
/// them.
struct SkillMetadata: Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let compatibleAgentTypes: [String]
    let origin: SkillOrigin
    let createdAt: Date
    let contentHash: String
}

/// A complete, saved Skill definition. All fields are immutable by design.
struct SkillDefinition: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let instructions: String
    let compatibleAgentTypes: [String]
    let origin: SkillOrigin
    let createdAt: Date
    let contentHash: String

    // These two fields keep the existing catalog UI useful without adding
    // connector-specific behavior to user-created Skills.
    let icon: String
    let connectorSlugs: [String]

    var displayName: String { name }
    var summary: String { description }
    var date: Date { createdAt }
    var isBuiltIn: Bool { origin == .builtIn }

    var compactMetadata: SkillMetadata {
        SkillMetadata(
            id: id,
            name: name,
            description: description,
            compatibleAgentTypes: compatibleAgentTypes,
            origin: origin,
            createdAt: createdAt,
            contentHash: contentHash
        )
    }

    init(
        id: String,
        name: String,
        description: String,
        instructions: String,
        compatibleAgentTypes: [String],
        origin: SkillOrigin,
        createdAt: Date,
        icon: String,
        connectorSlugs: [String],
        contentHash: String? = nil
    ) {
        self.id = id
        self.name = Self.normalizedText(name)
        self.description = Self.normalizedText(description)
        self.instructions = Self.normalizedText(instructions)
        self.compatibleAgentTypes = Self.normalizedAgentTypes(compatibleAgentTypes)
        self.origin = origin
        self.createdAt = createdAt
        self.icon = icon.isEmpty ? "sparkles" : icon
        self.connectorSlugs = connectorSlugs
        self.contentHash = contentHash ?? Self.makeContentHash(
            name: self.name,
            description: self.description,
            instructions: self.instructions,
            compatibleAgentTypes: self.compatibleAgentTypes
        )
    }

    /// Source compatibility for the original catalog-only initializer. New
    /// Skills should use the complete definition or a SkillDraft instead.
    init(
        id: String,
        displayName: String,
        summary: String,
        icon: String,
        connectorSlugs: [String],
        instructions: String
    ) {
        self.init(
            id: id,
            name: displayName,
            description: summary,
            instructions: instructions,
            compatibleAgentTypes: [],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: icon,
            connectorSlugs: connectorSlugs
        )
    }

    static func makeUserSkill(
        from draft: SkillDraft,
        id: String = UUID().uuidString,
        createdAt: Date = Date()
    ) -> SkillDefinition {
        SkillDefinition(
            id: id,
            name: draft.name,
            description: draft.description,
            instructions: draft.instructions,
            compatibleAgentTypes: draft.compatibleAgentTypes,
            origin: draft.origin,
            createdAt: createdAt,
            icon: draft.icon,
            connectorSlugs: draft.connectorSlugs
        )
    }

    static func contentHash(
        name: String,
        description: String,
        instructions: String,
        compatibleAgentTypes: [String]
    ) -> String {
        makeContentHash(
            name: normalizedText(name),
            description: normalizedText(description),
            instructions: normalizedText(instructions),
            compatibleAgentTypes: normalizedAgentTypes(compatibleAgentTypes)
        )
    }

    private static func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedAgentTypes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map(normalizedText)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func makeContentHash(
        name: String,
        description: String,
        instructions: String,
        compatibleAgentTypes: [String]
    ) -> String {
        let canonicalContent = [
            name,
            description,
            instructions,
            compatibleAgentTypes.joined(separator: "\u{1F}")
        ].joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(canonicalContent.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The editable, unsaved form used by manual creation, AI drafting, and
/// duplication. A draft has no persistence identity until it is saved.
struct SkillDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var instructions: String
    var compatibleAgentTypes: [String]
    var origin: SkillOrigin
    var icon: String
    var connectorSlugs: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        instructions: String = "",
        compatibleAgentTypes: [String] = [],
        origin: SkillOrigin = .manual,
        icon: String = "sparkles",
        connectorSlugs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.compatibleAgentTypes = compatibleAgentTypes
        self.origin = origin
        self.icon = icon
        self.connectorSlugs = connectorSlugs
    }

    init(copying skill: SkillDefinition) {
        self.init(
            name: skill.name,
            description: skill.description,
            instructions: skill.instructions,
            compatibleAgentTypes: skill.compatibleAgentTypes,
            origin: .duplicate,
            icon: skill.icon,
            connectorSlugs: skill.connectorSlugs
        )
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a name for this Skill."
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a short description."
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add the reusable instructions."
        }
        return nil
    }
}

/// Existing callers use `SkillIdentity`; keep that name as a compatibility
/// alias while the catalog now carries the complete immutable definition.
typealias SkillIdentity = SkillDefinition

enum SkillRegistry {
    /// This key is intentionally unchanged from the original Skills milestone.
    /// CompanionManager reads it directly, so stable built-in ids and this key
    /// preserve existing enabled-state data without a CompanionManager change.
    static let enabledSkillIDsDefaultsKey = "mackyEnabledSkillIDs"

    private static let userDefinitionsDefaultsKey = "mackySkillDefinitionsV1"

    private enum UserSkillLoadResult {
        case missing
        case loaded([SkillDefinition])
        case unreadable
    }

    /// Built-ins are never read from or written to local persistence.
    static let builtInSkills: [SkillIdentity] = [
        SkillIdentity(
            id: "meeting-assistant",
            name: "Meeting Assistant",
            description: "Preps you before meetings using your calendar, email, and reminders.",
            instructions: "When the user asks about an upcoming meeting, check their calendar for the event details, look for related email threads with the attendees, and surface anything they should know before joining.",
            compatibleAgentTypes: ["general", "assistant", "planner"],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: "calendar.badge.clock",
            connectorSlugs: ["googlecalendar", "gmail"]
        ),
        SkillIdentity(
            id: "email-assistant",
            name: "Email Assistant",
            description: "Reads, drafts, and sends email from voice requests.",
            instructions: "Handle email requests end to end: read unread mail, summarize threads, and draft or send replies in the user's voice. Confirm the action was taken in one short clause after doing it, not before.",
            compatibleAgentTypes: ["general", "assistant", "communicator"],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: "envelope.badge",
            connectorSlugs: ["gmail"]
        ),
        SkillIdentity(
            id: "research",
            name: "Research",
            description: "Looks things up and reads documents to answer open-ended questions.",
            instructions: "For open-ended or factual questions, gather information from the screen or attached documents before answering, and give a direct synthesized answer rather than a list of sources.",
            compatibleAgentTypes: ["general", "assistant", "researcher"],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: "magnifyingglass",
            connectorSlugs: []
        ),
        SkillIdentity(
            id: "code-review",
            name: "Code Review",
            description: "Checks pull request and issue status, and helps triage bugs.",
            instructions: "When asked about repository status, check open issues and pull requests, summarize what's failing or blocked, and offer to create or update an issue.",
            compatibleAgentTypes: ["general", "assistant", "developer"],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: "chevron.left.forwardslash.chevron.right",
            connectorSlugs: ["github"]
        ),
        SkillIdentity(
            id: "team-updates",
            name: "Team Updates",
            description: "Sends Slack updates and tracks Linear issues in one flow.",
            instructions: "When the user reports progress verbally, post the update to the right Slack channel and, if it corresponds to a tracked issue, move that issue's status in Linear to match.",
            compatibleAgentTypes: ["general", "assistant", "communicator"],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: "bubble.left.and.bubble.right",
            connectorSlugs: ["slack", "linear"]
        ),
        SkillIdentity(
            id: "music-control",
            name: "Music Control",
            description: "Plays, pauses, and queues music without leaving the notch.",
            instructions: "Handle playback requests (play, pause, skip, queue, volume) directly and briefly confirm what changed.",
            compatibleAgentTypes: ["general", "assistant", "operator"],
            origin: .builtIn,
            createdAt: Date(timeIntervalSince1970: 0),
            icon: "music.note",
            connectorSlugs: ["spotify"]
        )
    ]

    /// The registered set used by existing Home and CompanionManager callers.
    /// User definitions are loaded on demand so a saved Skill is immediately
    /// discoverable without changing those callers.
    static var skills: [SkillIdentity] {
        builtInSkills + userSkillDefinitions()
    }

    static func identity(forID id: String) -> SkillIdentity? {
        skills.first { $0.id == id }
    }

    static func userSkillDefinitions(
        defaults: UserDefaults = .standard,
        keyProvider: AgentEncryptionKeyProviding = AgentKeychainKeyProvider()
    ) -> [SkillIdentity] {
        switch loadUserSkills(defaults: defaults, keyProvider: keyProvider) {
        case .missing, .unreadable:
            return []
        case .loaded(let definitions):
            return definitions
        }
    }

    static func saveUserSkill(
        _ skill: SkillDefinition,
        defaults: UserDefaults = .standard,
        keyProvider: AgentEncryptionKeyProviding = AgentKeychainKeyProvider()
    ) throws {
        guard !skill.isBuiltIn else {
            throw SkillPersistenceError.cannotModifyBuiltIn
        }
        guard !builtInSkills.contains(where: { $0.id == skill.id }) else {
            throw SkillPersistenceError.duplicateID
        }

        var definitions: [SkillDefinition]
        switch loadUserSkills(defaults: defaults, keyProvider: keyProvider) {
        case .missing:
            definitions = []
        case .loaded(let existingDefinitions):
            definitions = existingDefinitions
        case .unreadable:
            throw SkillPersistenceError.unreadableData
        }

        guard !definitions.contains(where: { $0.id == skill.id }) else {
            throw SkillPersistenceError.duplicateID
        }
        definitions.append(skill)
        try persistUserSkills(definitions, defaults: defaults, keyProvider: keyProvider)
    }

    static func deleteUserSkill(
        withID id: String,
        defaults: UserDefaults = .standard,
        keyProvider: AgentEncryptionKeyProviding = AgentKeychainKeyProvider()
    ) throws {
        guard !builtInSkills.contains(where: { $0.id == id }) else {
            throw SkillPersistenceError.cannotModifyBuiltIn
        }

        let definitions: [SkillDefinition]
        switch loadUserSkills(defaults: defaults, keyProvider: keyProvider) {
        case .missing:
            definitions = []
        case .loaded(let existingDefinitions):
            definitions = existingDefinitions.filter { $0.id != id }
        case .unreadable:
            throw SkillPersistenceError.unreadableData
        }

        try persistUserSkills(definitions, defaults: defaults, keyProvider: keyProvider)
    }

    /// Cleans malformed values while retaining the original key and every
    /// non-empty string id. This keeps the legacy enabled-state contract intact
    /// and allows newly persisted user Skill ids to work through the unchanged
    /// CompanionManager methods.
    static func migrateEnabledSkillIDs(defaults: UserDefaults = .standard) {
        guard let values = defaults.array(forKey: enabledSkillIDsDefaultsKey) else {
            return
        }

        let ids = values.compactMap { value -> String? in
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let previousStringIDs = values as? [String] ?? []
        if ids != previousStringIDs || previousStringIDs.count != values.count {
            defaults.set(ids, forKey: enabledSkillIDsDefaultsKey)
        }
    }

    private static func persistUserSkills(
        _ definitions: [SkillDefinition],
        defaults: UserDefaults,
        keyProvider: AgentEncryptionKeyProviding
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let plaintext = try? encoder.encode(definitions) else {
            throw SkillPersistenceError.encodingFailed
        }

        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: keyProvider.loadOrCreateKey())
            guard let encryptedData = sealedBox.combined else {
                throw SkillPersistenceError.encryptionFailed
            }
            defaults.set(encryptedData, forKey: userDefinitionsDefaultsKey)
        } catch let error as SkillPersistenceError {
            throw error
        } catch {
            throw SkillPersistenceError.encryptionFailed
        }
    }

    private static func loadUserSkills(
        defaults: UserDefaults,
        keyProvider: AgentEncryptionKeyProviding
    ) -> UserSkillLoadResult {
        guard let data = defaults.data(forKey: userDefinitionsDefaultsKey) else {
            return .missing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        // Values written before encryption are still accepted once. The same
        // filtering used for the old plaintext catalog is applied before the
        // value is rewritten, so malformed and colliding entries do not survive
        // the migration.
        if let legacyDefinitions = try? decoder.decode([SkillDefinition].self, from: data) {
            let definitions = validatedUserSkills(legacyDefinitions)
            do {
                try persistUserSkills(definitions, defaults: defaults, keyProvider: keyProvider)
                return .loaded(definitions)
            } catch {
                return .unreadable
            }
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: keyProvider.loadOrCreateKey()
            )
            let definitions = try decoder.decode([SkillDefinition].self, from: plaintext)
            return .loaded(validatedUserSkills(definitions))
        } catch {
            // Authentication failures, malformed ciphertext, and unavailable or
            // mismatched keys all fail closed. Do not rewrite the stored value.
            return .unreadable
        }
    }

    private static func validatedUserSkills(
        _ definitions: [SkillDefinition]
    ) -> [SkillDefinition] {
        let builtInIDs = Set(builtInSkills.map(\.id))
        var seenIDs = Set<String>()
        return definitions
            .filter { !$0.isBuiltIn && !builtInIDs.contains($0.id) }
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

enum SkillPersistenceError: LocalizedError, Equatable {
    case cannotModifyBuiltIn
    case duplicateID
    case encodingFailed
    case encryptionFailed
    case unreadableData

    var errorDescription: String? {
        switch self {
        case .cannotModifyBuiltIn:
            return "Built-in Skills are immutable. Duplicate one to revise it."
        case .duplicateID:
            return "That Skill id is already in use."
        case .encodingFailed:
            return "Macky could not save this Skill locally."
        case .encryptionFailed:
            return "Macky could not encrypt this Skill locally."
        case .unreadableData:
            return "Macky could not read the saved Skills catalog."
        }
    }
}
