//
//  AgentModels.swift
//  leanring-buddy
//
//  Durable, local-only records for the General Agent. Event records are append-only;
//  task, job, and attempt records hold the current materialized state for fast UI reads.
//

import Foundation

struct AgentModel: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let solMedium = AgentModel(rawValue: "sol-medium")
}

enum AgentTaskStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case waiting
    case interrupted
    case completed
    case cancelled
    case failed
}

enum AgentJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case waiting
    case interrupted
    case completed
    case cancelled
    case failed
}

enum AgentAttemptStatus: String, Codable, Equatable, Sendable {
    case running
    case waiting
    case interrupted
    case completed
    case cancelled
    case failed
}

enum AgentQuestionStatus: String, Codable, Equatable, Sendable {
    case open
    case answered
    case expired
}

enum AgentResultStatus: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
    case interrupted
}

enum AgentSourceKind: String, Codable, Equatable, Sendable {
    case voice
    case text
    case automation
    case restored
}

struct AgentSource: Codable, Equatable, Sendable {
    let kind: AgentSourceKind
    let detail: String?
    let capturedAt: Date

    init(kind: AgentSourceKind, detail: String? = nil, capturedAt: Date = Date()) {
        self.kind = kind
        self.detail = detail
        self.capturedAt = capturedAt
    }
}

/// A task stores a value snapshot rather than a live `SkillIdentity`, so later Skill
/// catalog edits cannot change an already-submitted task's instructions.
struct AgentSkillSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let instructions: String
    let capturedAt: Date

    init(id: String, displayName: String, instructions: String, capturedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.instructions = instructions
        self.capturedAt = capturedAt
    }
}

struct AgentAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let originalFilename: String
    let mediaType: String?
    let byteCount: Int64
    /// Relative to AgentAttachmentStore.rootDirectory. Keeping this relative prevents
    /// persisted records from becoming tied to a particular user-home path.
    let storedRelativePath: String
    let copiedAt: Date

    init(
        id: UUID = UUID(),
        originalFilename: String,
        mediaType: String? = nil,
        byteCount: Int64,
        storedRelativePath: String,
        copiedAt: Date = Date()
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.storedRelativePath = storedRelativePath
        self.copiedAt = copiedAt
    }
}

enum AgentArtifactEncoding: String, Codable, Equatable, Sendable {
    case utf8
    case base64
}

struct AgentArtifact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let jobID: UUID
    let attemptID: UUID
    let providerCallID: String?
    let name: String
    let mediaType: String
    let encoding: AgentArtifactEncoding
    let content: Data
    let createdAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID,
        providerCallID: String? = nil,
        name: String,
        mediaType: String,
        encoding: AgentArtifactEncoding,
        content: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.jobID = jobID
        self.attemptID = attemptID
        self.providerCallID = providerCallID
        self.name = name
        self.mediaType = mediaType
        self.encoding = encoding
        self.content = content
        self.createdAt = createdAt
    }
}

struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let jobID: UUID
    let attemptID: UUID?
    /// Provider function-call id used to return the user's eventual answer in a
    /// stateless follow-up request. Nil only for state written before protocol v1.
    let providerCallID: String?
    let prompt: String
    let options: [String]
    let createdAt: Date
    /// Questions are intentionally short lived. The value is always derived from the
    /// local creation time and cannot be extended by a remote response.
    let expiresAt: Date
    var status: AgentQuestionStatus
    var answer: String?
    var answeredAt: Date?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID?,
        providerCallID: String? = nil,
        prompt: String,
        options: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.jobID = jobID
        self.attemptID = attemptID
        self.providerCallID = providerCallID
        self.prompt = prompt
        self.options = options
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(AgentRetentionPolicy.questionLifetime)
        self.status = .open
        self.answer = nil
        self.answeredAt = nil
    }

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

struct AgentResult: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let jobID: UUID
    let attemptID: UUID?
    let status: AgentResultStatus
    let summary: String
    let markdown: String
    let sources: [AgentFinalResultSource]
    let artifactIDs: [UUID]
    let limitations: [String]
    let suggestedActions: [String]
    let partial: Bool
    let completedAt: Date
    let errorDetail: String?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID?,
        status: AgentResultStatus,
        summary: String,
        markdown: String? = nil,
        sources: [AgentFinalResultSource] = [],
        artifactIDs: [UUID] = [],
        limitations: [String] = [],
        suggestedActions: [String] = [],
        partial: Bool = false,
        completedAt: Date = Date(),
        errorDetail: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.jobID = jobID
        self.attemptID = attemptID
        self.status = status
        self.summary = summary
        self.markdown = markdown ?? summary
        self.sources = sources
        self.artifactIDs = artifactIDs
        self.limitations = limitations
        self.suggestedActions = suggestedActions
        self.partial = partial
        self.completedAt = completedAt
        self.errorDetail = errorDetail
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case jobID
        case attemptID
        case status
        case summary
        case markdown
        case sources
        case artifactIDs
        case limitations
        case suggestedActions
        case partial
        case completedAt
        case errorDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        attemptID = try container.decodeIfPresent(UUID.self, forKey: .attemptID)
        status = try container.decode(AgentResultStatus.self, forKey: .status)
        summary = try container.decode(String.self, forKey: .summary)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? summary
        sources = try container.decodeIfPresent([AgentFinalResultSource].self, forKey: .sources) ?? []
        artifactIDs = try container.decodeIfPresent([UUID].self, forKey: .artifactIDs) ?? []
        limitations = try container.decodeIfPresent([String].self, forKey: .limitations) ?? []
        suggestedActions = try container.decodeIfPresent([String].self, forKey: .suggestedActions) ?? []
        partial = try container.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)
    }
}

struct AgentSteeringInstruction: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let requestedAt: Date

    init(id: UUID = UUID(), text: String, requestedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.requestedAt = requestedAt
    }
}

struct AgentTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let agentID: String
    let instruction: String
    let source: AgentSource
    let skillSnapshots: [AgentSkillSnapshot]
    let attachments: [AgentAttachment]
    var parentGroups: [AgentParentGroup]
    let createdAt: Date
    var updatedAt: Date
    var status: AgentTaskStatus
    var resultIDs: [UUID]

    init(
        id: UUID = UUID(),
        agentID: String,
        instruction: String,
        source: AgentSource,
        skillSnapshots: [AgentSkillSnapshot],
        attachments: [AgentAttachment],
        parentGroups: [AgentParentGroup] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.agentID = agentID
        self.instruction = instruction
        self.source = source
        self.skillSnapshots = skillSnapshots
        self.attachments = attachments
        self.parentGroups = parentGroups
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = .queued
        self.resultIDs = []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agentID
        case instruction
        case source
        case skillSnapshots
        case attachments
        case parentGroups
        case createdAt
        case updatedAt
        case status
        case resultIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        agentID = try container.decode(String.self, forKey: .agentID)
        instruction = try container.decode(String.self, forKey: .instruction)
        source = try container.decode(AgentSource.self, forKey: .source)
        skillSnapshots = try container.decode([AgentSkillSnapshot].self, forKey: .skillSnapshots)
        attachments = try container.decode([AgentAttachment].self, forKey: .attachments)
        parentGroups = try container.decodeIfPresent([AgentParentGroup].self, forKey: .parentGroups) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        status = try container.decode(AgentTaskStatus.self, forKey: .status)
        resultIDs = try container.decode([UUID].self, forKey: .resultIDs)
    }
}

struct AgentParentGroup: Codable, Equatable, Identifiable, Sendable {
    static let maximumJobCount = 3

    let id: UUID
    let taskID: UUID
    let jobIDs: [UUID]

    init(id: UUID = UUID(), taskID: UUID, jobIDs: [UUID]) throws {
        guard !jobIDs.isEmpty, jobIDs.count <= Self.maximumJobCount else {
            throw AgentModelError.invalidParentGroupSize(jobIDs.count)
        }
        self.id = id
        self.taskID = taskID
        self.jobIDs = jobIDs
    }
}

struct AgentJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let parentGroupID: UUID?
    let instruction: String
    let createdAt: Date
    var updatedAt: Date
    var status: AgentJobStatus
    var resultID: UUID?
    var pendingSteering: [AgentSteeringInstruction]
    /// Encrypted local checkpoint for stateless provider continuation. Optional so
    /// state written before protocol v1 remains decodable.
    var continuationItems: [AgentContinuationItem]?
    var toolOutputs: [AgentToolResponse]?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        parentGroupID: UUID? = nil,
        instruction: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.parentGroupID = parentGroupID
        self.instruction = instruction
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = .queued
        self.resultID = nil
        self.pendingSteering = []
        self.continuationItems = []
        self.toolOutputs = []
    }
}

struct AgentAttempt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let jobID: UUID
    let ordinal: Int
    let startedAt: Date
    var endedAt: Date?
    var status: AgentAttemptStatus

    init(
        id: UUID = UUID(),
        taskID: UUID,
        jobID: UUID,
        ordinal: Int,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.jobID = jobID
        self.ordinal = ordinal
        self.startedAt = startedAt
        self.endedAt = nil
        self.status = .running
    }
}

enum AgentEventKind: String, Codable, Equatable, Sendable {
    case taskCreated
    case jobQueued
    case attemptStarted
    case responseTextReceived
    case toolRequested
    case attachmentChunkProvided
    case artifactCreated
    case questionAsked
    case questionAnswered
    case questionExpired
    case waiting
    case steeringQueued
    case steeringApplied
    case resultFinalized
    case completed
    case cancellationRequested
    case cancelled
    case failed
    case interrupted
    case restarted
}

/// This is the only mutable timeline in the harness: records are only appended and
/// never altered. Retention removes whole expired task histories together.
struct AgentEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sequence: Int64
    let taskID: UUID
    let jobID: UUID?
    let attemptID: UUID?
    let kind: AgentEventKind
    let message: String?
    let metadata: [String: String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sequence: Int64,
        taskID: UUID,
        jobID: UUID? = nil,
        attemptID: UUID? = nil,
        kind: AgentEventKind,
        message: String? = nil,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sequence = sequence
        self.taskID = taskID
        self.jobID = jobID
        self.attemptID = attemptID
        self.kind = kind
        self.message = message
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

struct AgentPersistentState: Codable, Equatable, Sendable {
    var tasks: [AgentTask]
    var jobs: [AgentJob]
    var attempts: [AgentAttempt]
    var events: [AgentEvent]
    var results: [AgentResult]
    var artifacts: [AgentArtifact]
    var questions: [AgentQuestion]
    var nextEventSequence: Int64

    static let empty = AgentPersistentState(
        tasks: [],
        jobs: [],
        attempts: [],
        events: [],
        results: [],
        artifacts: [],
        questions: [],
        nextEventSequence: 1
    )
}

struct AgentStoreSnapshot: Equatable, Sendable {
    let tasks: [AgentTask]
    let jobs: [AgentJob]
    let attempts: [AgentAttempt]
    let events: [AgentEvent]
    let results: [AgentResult]
    let artifacts: [AgentArtifact]
    let questions: [AgentQuestion]

    init(state: AgentPersistentState) {
        tasks = state.tasks
        jobs = state.jobs
        attempts = state.attempts
        events = state.events
        results = state.results
        artifacts = state.artifacts
        questions = state.questions
    }
}

nonisolated enum AgentRetentionPolicy {
    static let recentLifetime: TimeInterval = 4 * 60 * 60
    static let historyLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let questionLifetime: TimeInterval = 24 * 60 * 60

    static func recentTasks(in tasks: [AgentTask], at date: Date = Date()) -> [AgentTask] {
        tasks
            .filter { date.timeIntervalSince($0.updatedAt) <= recentLifetime }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func historyTasks(in tasks: [AgentTask], at date: Date = Date()) -> [AgentTask] {
        tasks
            .filter { date.timeIntervalSince($0.updatedAt) <= historyLifetime }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

enum AgentModelError: LocalizedError, Equatable {
    case invalidParentGroupSize(Int)

    var errorDescription: String? {
        switch self {
        case .invalidParentGroupSize(let count):
            return "A parent group must contain between one and \(AgentParentGroup.maximumJobCount) jobs; received \(count)."
        }
    }
}
