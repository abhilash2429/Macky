//
//  AgentContracts.swift
//  leanring-buddy
//

import Foundation

enum AgentToolName: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case attachmentChunk = "read_attachment"
    case runJavaScript = "run_javascript"
    case artifact = "create_artifact"
    case question = "ask_question"
    case finalResult = "final_result"
}

struct AgentToolContract: Codable, Equatable, Identifiable, Sendable {
    let name: AgentToolName
    let description: String

    var id: String { name.rawValue }

    static let generalAgentContracts: [AgentToolContract] = [
        AgentToolContract(
            name: .attachmentChunk,
            description: "Read a bounded byte range from an explicitly copied task attachment."
        ),
        AgentToolContract(
            name: .runJavaScript,
            description: "Run JavaScript through the local, sandboxed executor."
        ),
        AgentToolContract(
            name: .artifact,
            description: "Create a local artifact attached to the current task."
        ),
        AgentToolContract(
            name: .question,
            description: "Ask the user a question. It expires after 24 hours."
        ),
        AgentToolContract(
            name: .finalResult,
            description: "Finalize the current job with a local result."
        )
    ]
}

struct AgentAttachmentChunkRequest: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let offset: Int64
    /// This remains optional only to preserve the local attachment-store interface.
    /// The v1 wire decoder requires a value between 1 byte and 1 MiB.
    let byteCount: Int64?

    init(attachmentID: UUID, offset: Int64, byteCount: Int64? = nil) {
        self.attachmentID = attachmentID
        self.offset = offset
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case offset
        case byteCount = "byte_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attachmentID = try container.decode(UUID.self, forKey: .attachmentID)
        let offset = try container.decode(Int64.self, forKey: .offset)
        let byteCount = try container.decode(Int64.self, forKey: .byteCount)
        guard offset >= 0, (1...1_048_576).contains(byteCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .byteCount,
                in: container,
                debugDescription: "Attachment reads must use a non-negative offset and a byte count from 1 through 1,048,576."
            )
        }
        self.attachmentID = attachmentID
        self.offset = offset
        self.byteCount = byteCount
    }

    func encode(to encoder: Encoder) throws {
        guard let byteCount else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Attachment reads require a byte count."
                )
            )
        }
        guard offset >= 0, (1...1_048_576).contains(byteCount) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Attachment reads must use a non-negative offset and a byte count from 1 through 1,048,576."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attachmentID, forKey: .attachmentID)
        try container.encode(offset, forKey: .offset)
        try container.encode(byteCount, forKey: .byteCount)
    }
}

struct AgentAttachmentChunk: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let offset: Int64
    let content: Data
    let isFinalChunk: Bool
}

struct AgentArtifactRequest: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let encoding: AgentArtifactEncoding
    let content: Data

    init(name: String, mediaType: String, encoding: AgentArtifactEncoding, content: Data) {
        self.name = name
        self.mediaType = mediaType
        self.encoding = encoding
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case mediaType = "media_type"
        case encoding
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let mediaType = try container.decode(String.self, forKey: .mediaType)
        let encoding = try container.decode(AgentArtifactEncoding.self, forKey: .encoding)
        let serializedContent = try container.decode(String.self, forKey: .content)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .content,
                in: container,
                debugDescription: "Artifacts require a name and media type."
            )
        }

        let content: Data
        switch encoding {
        case .utf8:
            content = Data(serializedContent.utf8)
        case .base64:
            guard let decodedContent = Data(base64Encoded: serializedContent) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .content,
                    in: container,
                    debugDescription: "Base64 artifact content is invalid."
                )
            }
            content = decodedContent
        }

        self.name = name
        self.mediaType = mediaType
        self.encoding = encoding
        self.content = content
    }

    func encode(to encoder: Encoder) throws {
        let serializedContent: String
        switch encoding {
        case .utf8:
            guard let stringContent = String(data: content, encoding: .utf8) else {
                throw EncodingError.invalidValue(
                    content,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "UTF-8 artifact content must be valid UTF-8."
                    )
                )
            }
            serializedContent = stringContent
        case .base64:
            serializedContent = content.base64EncodedString()
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(encoding, forKey: .encoding)
        try container.encode(serializedContent, forKey: .content)
    }
}

struct AgentQuestionRequest: Codable, Equatable, Sendable {
    let prompt: String
    let options: [String]

    init(prompt: String, options: [String] = []) {
        self.prompt = prompt
        self.options = options
    }
}

struct AgentFinalResultSource: Codable, Equatable, Sendable {
    let title: String
    let url: String
}

struct AgentFinalResultRequest: Codable, Equatable, Sendable {
    let spokenSummary: String
    let markdown: String
    let sources: [AgentFinalResultSource]
    let artifactIDs: [UUID]
    let limitations: [String]
    let suggestedActions: [String]
    let partial: Bool

    /// Existing local result persistence stores the spoken completion summary.
    var summary: String { spokenSummary }

    init(
        spokenSummary: String,
        markdown: String,
        sources: [AgentFinalResultSource],
        artifactIDs: [UUID],
        limitations: [String],
        suggestedActions: [String],
        partial: Bool
    ) {
        self.spokenSummary = spokenSummary
        self.markdown = markdown
        self.sources = sources
        self.artifactIDs = artifactIDs
        self.limitations = limitations
        self.suggestedActions = suggestedActions
        self.partial = partial
    }

    /// Temporary local-store compatibility while result persistence adopts the v1
    /// presentation fields. It does not affect the v1 wire shape.
    init(summary: String, artifactIDs: [UUID] = []) {
        self.init(
            spokenSummary: summary,
            markdown: summary,
            sources: [],
            artifactIDs: artifactIDs,
            limitations: [],
            suggestedActions: [],
            partial: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case spokenSummary = "spoken_summary"
        case markdown
        case sources
        case artifactIDs = "artifact_ids"
        case limitations
        case suggestedActions = "suggested_actions"
        case partial
    }
}

/// The function-call argument form for the `run_javascript` tool. The executor keeps
/// its own `Data`-based request because it communicates over a separate local XPC API.
struct AgentRunJavaScriptRequest: Codable, Equatable, Sendable {
    let source: String
    let inputJSON: String?

    private enum CodingKeys: String, CodingKey {
        case source
        case inputJSON = "input_json"
    }

    init(source: String, inputJSON: String?) {
        self.source = source
        self.inputJSON = inputJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decode(String.self, forKey: .source)
        self.inputJSON = try container.decode(String?.self, forKey: .inputJSON)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(inputJSON, forKey: .inputJSON)
    }
}

struct AgentToolCall: Codable, Equatable, Identifiable, Sendable {
    /// A Macky-local event identifier. It is intentionally distinct from Azure's
    /// function-call ID so local persistence never treats provider IDs as primary keys.
    let id: UUID
    let providerCallID: String
    let name: AgentToolName
    /// JSON object text provided by the function call. It remains opaque until the
    /// local runtime dispatches the named, strongly typed contract.
    let arguments: String

    init(id: UUID = UUID(), providerCallID: String, name: AgentToolName, arguments: String) {
        self.id = id
        self.providerCallID = providerCallID
        self.name = name
        self.arguments = arguments
    }

    func decode<Payload: Decodable>(_ type: Payload.Type) throws -> Payload {
        try JSONDecoder().decode(type, from: Data(arguments.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerCallID = "provider_call_id"
        case name
        case arguments
    }
}

struct AgentToolResponse: Codable, Equatable, Identifiable, Sendable {
    /// Azure function-call ID, which is the ID required by `function_call_output`.
    let providerCallID: String
    let output: String

    var id: String { providerCallID }

    init(providerCallID: String, output: String) {
        self.providerCallID = providerCallID
        self.output = output
    }

    init<Payload: Encodable>(providerCallID: String, payload: Payload) throws {
        let outputData = try JSONEncoder().encode(payload)
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                payload,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Tool output must be UTF-8 JSON."
                )
            )
        }
        self.init(providerCallID: providerCallID, output: output)
    }

    private enum CodingKeys: String, CodingKey {
        case providerCallID = "call_id"
        case output
    }
}

/// JavaScript execution is intentionally a narrow dependency boundary. The concrete
/// executor lives in a separately owned file and may provide a sandbox; this harness
/// never imports or constructs that client directly.
struct AgentJavaScriptExecutionRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: String
    let input: Data?

    init(id: UUID = UUID(), source: String, input: Data? = nil) {
        self.id = id
        self.source = source
        self.input = input
    }
}

struct AgentJavaScriptExecutionResult: Codable, Equatable, Sendable {
    let output: Data
    let mediaType: String

    init(output: Data, mediaType: String = "application/json") {
        self.output = output
        self.mediaType = mediaType
    }
}

@MainActor
protocol AgentJavaScriptExecuting: AnyObject {
    func execute(_ request: AgentJavaScriptExecutionRequest) async throws -> AgentJavaScriptExecutionResult
}

@MainActor
final class AgentUnavailableJavaScriptExecutor: AgentJavaScriptExecuting {
    func execute(_ request: AgentJavaScriptExecutionRequest) async throws -> AgentJavaScriptExecutionResult {
        throw AgentRuntimeError.javaScriptExecutorUnavailable
    }
}

enum AgentOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case general
    case skillDraft = "skill-draft"
}

/// Flat, server-owned capability data from `GET /agent-config`.
struct AgentRemoteConfiguration: Codable, Equatable, Sendable {
    static let supportedProtocolVersion = 1

    let protocolVersion: Int
    let enabled: Bool
    let developmentOnly: Bool
    let agentID: String
    let displayName: String
    let model: AgentModel
    let operations: [AgentOperation]
    let webSearch: Bool
    let tools: [AgentToolName]

    init(
        enabled: Bool,
        developmentOnly: Bool,
        agentID: String,
        displayName: String,
        model: AgentModel,
        operations: [AgentOperation],
        webSearch: Bool,
        tools: [AgentToolName]
    ) {
        self.protocolVersion = Self.supportedProtocolVersion
        self.enabled = enabled
        self.developmentOnly = developmentOnly
        self.agentID = agentID
        self.displayName = displayName
        self.model = model
        self.operations = operations
        self.webSearch = webSearch
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case enabled
        case developmentOnly = "development_only"
        case agentID = "agent_id"
        case displayName = "display_name"
        case model
        case operations
        case webSearch = "web_search"
        case tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported Agent protocol version."
            )
        }
        self.protocolVersion = protocolVersion
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.developmentOnly = try container.decode(Bool.self, forKey: .developmentOnly)
        self.agentID = try container.decode(String.self, forKey: .agentID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.model = try container.decode(AgentModel.self, forKey: .model)
        self.operations = try container.decode([AgentOperation].self, forKey: .operations)
        self.webSearch = try container.decode(Bool.self, forKey: .webSearch)
        self.tools = try container.decode([AgentToolName].self, forKey: .tools)
    }
}

/// The three continuation shapes allowed by the stateless v1 request. Keeping this a
/// closed enum prevents arbitrary provider output or tool records reaching the Worker.
enum AgentContinuationItem: Codable, Equatable, Sendable {
    case reasoning(id: String, encryptedContent: String)
    case functionCall(id: String, callID: String, name: AgentToolName, arguments: String)
    case message(id: String, text: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case encryptedContent = "encrypted_content"
        case callID = "call_id"
        case name
        case arguments
        case role
        case status
        case content
    }

    private enum Kind: String, Codable {
        case reasoning
        case functionCall = "function_call"
        case message
    }

    private struct MessageContent: Codable, Equatable {
        let type: String
        let text: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .reasoning:
            self = .reasoning(
                id: try container.decode(String.self, forKey: .id),
                encryptedContent: try container.decode(String.self, forKey: .encryptedContent)
            )
        case .functionCall:
            self = .functionCall(
                id: try container.decode(String.self, forKey: .id),
                callID: try container.decode(String.self, forKey: .callID),
                name: try container.decode(AgentToolName.self, forKey: .name),
                arguments: try container.decode(String.self, forKey: .arguments)
            )
        case .message:
            let role = try container.decode(String.self, forKey: .role)
            let status = try container.decode(String.self, forKey: .status)
            let content = try container.decode([MessageContent].self, forKey: .content)
            guard role == "assistant",
                  status == "completed",
                  content.count == 1,
                  content[0].type == "output_text" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .content,
                    in: container,
                    debugDescription: "Agent message continuation items require one assistant output_text value."
                )
            }
            self = .message(
                id: try container.decode(String.self, forKey: .id),
                text: content[0].text
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .reasoning(id, encryptedContent):
            try container.encode(Kind.reasoning, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(encryptedContent, forKey: .encryptedContent)
        case let .functionCall(id, callID, name, arguments):
            try container.encode(Kind.functionCall, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case let .message(id, text):
            try container.encode(Kind.message, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode("completed", forKey: .status)
            try container.encode("assistant", forKey: .role)
            try container.encode(
                [MessageContent(type: "output_text", text: text)],
                forKey: .content
            )
        }
    }

    var functionCall: (id: String, callID: String, name: AgentToolName, arguments: String)? {
        guard case let .functionCall(id, callID, name, arguments) = self else { return nil }
        return (id, callID, name, arguments)
    }

    var isResponseContinuation: Bool {
        switch self {
        case .reasoning, .message:
            return true
        case .functionCall:
            return false
        }
    }
}

struct AgentResponseRequest: Codable, Equatable, Sendable {
    static let supportedProtocolVersion = 1

    let protocolVersion: Int
    let agent: String
    let operation: AgentOperation
    let input: String
    let webSearch: Bool
    let continuationItems: [AgentContinuationItem]
    let toolOutputs: [AgentToolResponse]

    init(
        agent: String = "general",
        operation: AgentOperation = .general,
        input: String,
        webSearch: Bool = false,
        continuationItems: [AgentContinuationItem] = [],
        toolOutputs: [AgentToolResponse] = []
    ) {
        self.protocolVersion = Self.supportedProtocolVersion
        self.agent = agent
        self.operation = operation
        self.input = input
        self.webSearch = webSearch
        self.continuationItems = continuationItems
        self.toolOutputs = toolOutputs
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case agent
        case operation
        case input
        case webSearch = "web_search"
        case continuationItems = "continuation_items"
        case toolOutputs = "tool_outputs"
    }
}

enum AgentResponseStreamEventKind: String, Codable, Equatable, Sendable {
    case text
    case continuation
    case toolCall = "tool_call"
    case completed
    case error
}

/// A normalized Worker SSE message. Azure event envelopes and raw provider details
/// are intentionally not represented in Swift.
struct AgentResponseStreamEvent: Codable, Equatable, Sendable {
    static let supportedProtocolVersion = 1

    let protocolVersion: Int
    let kind: AgentResponseStreamEventKind
    let text: String?
    let continuationItem: AgentContinuationItem?
    let toolCall: AgentToolCall?
    let errorDetail: String?

    init(
        kind: AgentResponseStreamEventKind,
        text: String? = nil,
        continuationItem: AgentContinuationItem? = nil,
        toolCall: AgentToolCall? = nil,
        errorDetail: String? = nil
    ) {
        self.protocolVersion = Self.supportedProtocolVersion
        self.kind = kind
        self.text = text
        self.continuationItem = continuationItem
        self.toolCall = toolCall
        self.errorDetail = errorDetail
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kind
        case text
        case continuationItem = "continuation_item"
        case toolCall = "tool_call"
        case errorDetail = "error_detail"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported Agent protocol version."
            )
        }
        let kind = try container.decode(AgentResponseStreamEventKind.self, forKey: .kind)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let continuationItem = try container.decodeIfPresent(AgentContinuationItem.self, forKey: .continuationItem)
        let toolCall = try container.decodeIfPresent(AgentToolCall.self, forKey: .toolCall)
        let errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)

        switch kind {
        case .text:
            guard text != nil else {
                throw DecodingError.keyNotFound(
                    CodingKeys.text,
                    DecodingError.Context(codingPath: container.codingPath, debugDescription: "Text events require text.")
                )
            }
        case .continuation:
            guard continuationItem?.isResponseContinuation == true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .continuationItem,
                    in: container,
                    debugDescription: "Continuation events require a reasoning or assistant message item."
                )
            }
        case .toolCall:
            guard let continuation = continuationItem?.functionCall,
                  let toolCall,
                  continuation.callID == toolCall.providerCallID,
                  continuation.name == toolCall.name,
                  continuation.arguments == toolCall.arguments else {
                throw DecodingError.dataCorruptedError(
                    forKey: .toolCall,
                    in: container,
                    debugDescription: "Tool-call events must pair a matching function-call continuation item with a local tool call."
                )
            }
        case .completed:
            break
        case .error:
            guard errorDetail != nil else {
                throw DecodingError.keyNotFound(
                    CodingKeys.errorDetail,
                    DecodingError.Context(codingPath: container.codingPath, debugDescription: "Error events require error_detail.")
                )
            }
        }

        self.protocolVersion = protocolVersion
        self.kind = kind
        self.text = text
        self.continuationItem = continuationItem
        self.toolCall = toolCall
        self.errorDetail = errorDetail
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(continuationItem, forKey: .continuationItem)
        try container.encodeIfPresent(toolCall, forKey: .toolCall)
        try container.encodeIfPresent(errorDetail, forKey: .errorDetail)
    }
}

protocol AgentAPIServing: Sendable {
    func fetchConfiguration(for definition: AgentDefinition) async throws -> AgentRemoteConfiguration
    func streamResponse(_ request: AgentResponseRequest) async -> AsyncThrowingStream<AgentResponseStreamEvent, Error>
}

protocol AgentSessionTokenProviding: Sendable {
    func sessionToken() async -> String?
    func refreshSessionToken(rejecting rejectedToken: String) async -> String?
}

extension AgentSessionTokenProviding {
    func refreshSessionToken(rejecting rejectedToken: String) async -> String? {
        _ = rejectedToken
        return nil
    }
}

protocol AgentStatePersisting: Sendable {
    func load() async throws -> AgentPersistentState
    func save(_ state: AgentPersistentState) async throws
}

protocol AgentAttachmentAccessing: Sendable {
    func copyAttachments(from sourceURLs: [URL], for taskID: UUID) async throws -> [AgentAttachment]
    func chunk(for request: AgentAttachmentChunkRequest, in task: AgentTask) async throws -> AgentAttachmentChunk
    func delete(_ attachments: [AgentAttachment]) async
}

enum AgentRuntimeError: LocalizedError, Equatable {
    case unknownAgent(String)
    case unsafeRemoteConfiguration
    case invalidRemoteConfiguration
    case missingTask(UUID)
    case missingJob(UUID)
    case missingAttempt(UUID)
    case invalidToolCall
    case responseEndedWithoutResult
    case remoteResponseUnavailable
    case javaScriptExecutorUnavailable
    case invalidQuestion
    case invalidSteering
    case finalResultSupersededBySteering
    case taskNotCancellable
    case noProgress

    var errorDescription: String? {
        switch self {
        case .unknownAgent(let agentID):
            return "No registered agent exists for \(agentID)."
        case .unsafeRemoteConfiguration:
            return "The remote configuration requested cloud state or external effects, which the General Agent does not permit."
        case .invalidRemoteConfiguration:
            return "The remote configuration does not match the registered General Agent."
        case .missingTask:
            return "The requested agent task no longer exists."
        case .missingJob:
            return "The requested agent job no longer exists."
        case .missingAttempt:
            return "The requested agent attempt no longer exists."
        case .invalidToolCall:
            return "The agent sent an invalid tool request."
        case .responseEndedWithoutResult:
            return "The agent response ended before it produced a final result."
        case .remoteResponseUnavailable:
            return "The agent response service was temporarily unavailable."
        case .javaScriptExecutorUnavailable:
            return "JavaScript execution is not available in this build."
        case .invalidQuestion:
            return "The question is unavailable or has expired."
        case .invalidSteering:
            return "Steering text must not be empty."
        case .finalResultSupersededBySteering:
            return "New steering arrived before the result was finalized."
        case .taskNotCancellable:
            return "Only queued, running, or waiting agent tasks can be cancelled."
        case .noProgress:
            return "The agent repeated the same local step without making progress."
        }
    }
}
