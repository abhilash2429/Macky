//
//  AgentSkillDraftingProvider.swift
//  leanring-buddy
//

import Foundation

/// Drafts a Skill through the stateless General Agent without persisting or
/// enabling the returned definition.
final class AgentSkillDraftingProvider: SkillDraftingProvider, @unchecked Sendable {
    private let apiClient: AgentAPIServing
    private let agentDefinition: AgentDefinition

    init(
        apiClient: AgentAPIServing = AgentAPIClient(),
        agentDefinition: AgentDefinition = AgentRegistry.general
    ) {
        self.apiClient = apiClient
        self.agentDefinition = agentDefinition
    }

    func draftSkill(for prompt: String) async throws -> SkillDraft {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AgentSkillDraftingProviderError.invalidPrompt
        }

        let configuration = try await apiClient.fetchConfiguration(for: agentDefinition)
        try validate(configuration)

        let request = AgentResponseRequest(
            agent: agentDefinition.id,
            operation: .skillDraft,
            input: Self.makePrompt(for: trimmedPrompt),
            webSearch: false
        )

        let stream = await apiClient.streamResponse(request)
        for try await event in stream {
            switch event.kind {
            case .text, .continuation:
                continue

            case .toolCall:
                guard let toolCall = event.toolCall else {
                    throw AgentSkillDraftingProviderError.invalidStreamEvent
                }
                guard toolCall.name == .finalResult else {
                    throw AgentSkillDraftingProviderError.unsupportedTool(toolCall.name)
                }
                return try decodeDraft(from: toolCall)

            case .completed:
                throw AgentSkillDraftingProviderError.responseEndedWithoutDraft

            case .error:
                throw AgentSkillDraftingProviderError.streamFailure(
                    event.errorDetail ?? "The Skill drafting stream failed."
                )
            }
        }

        throw AgentSkillDraftingProviderError.responseEndedWithoutDraft
    }

    private func validate(_ configuration: AgentRemoteConfiguration) throws {
        guard configuration.enabled else {
            throw AgentSkillDraftingProviderError.disabledConfiguration
        }

        let configuredTools = Set(configuration.tools)
        let expectedTools = Set(agentDefinition.toolContracts.map(\.name))
        guard configuration.protocolVersion == AgentRemoteConfiguration.supportedProtocolVersion,
              configuration.developmentOnly,
              configuration.agentID == agentDefinition.id,
              configuration.model == agentDefinition.model,
              configuration.operations.contains(.skillDraft),
              configuredTools == expectedTools else {
            throw AgentSkillDraftingProviderError.invalidConfiguration
        }
    }

    private func decodeDraft(from toolCall: AgentToolCall) throws -> SkillDraft {
        let finalResult: AgentFinalResultRequest
        do {
            finalResult = try toolCall.decode(AgentFinalResultRequest.self)
        } catch {
            throw AgentSkillDraftingProviderError.malformedDraft
        }

        guard let markdownData = finalResult.markdown.data(using: .utf8) else {
            throw AgentSkillDraftingProviderError.malformedDraft
        }

        do {
            guard let decodedObject = try JSONSerialization.jsonObject(with: markdownData) as? [String: Any],
                  Set(decodedObject.keys) == Self.skillDraftKeys else {
                throw AgentSkillDraftingProviderError.malformedDraft
            }
        } catch let error as AgentSkillDraftingProviderError {
            throw error
        } catch {
            throw AgentSkillDraftingProviderError.malformedDraft
        }

        let payload: SkillDraftPayload
        do {
            payload = try JSONDecoder().decode(SkillDraftPayload.self, from: markdownData)
        } catch {
            throw AgentSkillDraftingProviderError.malformedDraft
        }

        let draft = SkillDraft(
            name: payload.name,
            description: payload.description,
            instructions: payload.instructions,
            compatibleAgentTypes: payload.compatibleAgentTypes,
            origin: .aiDraft
        )
        guard draft.validationError == nil else {
            throw AgentSkillDraftingProviderError.invalidDraft
        }
        return draft
    }

    private static func makePrompt(for prompt: String) -> String {
        """
        Draft one reusable Macky Skill from the user's request below.

        Finish by calling final_result exactly once. The final_result.markdown value must be only one JSON object with exactly these four keys: name, description, instructions, compatible_agent_types. Use this shape: {"name":"...","description":"...","instructions":"...","compatible_agent_types":["..."]}. Do not use Markdown fences, add extra keys, or include any text before or after the JSON. Do not save, enable, install, execute, or claim to have changed anything.

        User request:
        \(prompt)
        """
    }

    private static let skillDraftKeys: Set<String> = [
        "name",
        "description",
        "instructions",
        "compatible_agent_types"
    ]
}

private struct SkillDraftPayload: Decodable {
    let name: String
    let description: String
    let instructions: String
    let compatibleAgentTypes: [String]

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case instructions
        case compatibleAgentTypes = "compatible_agent_types"
    }
}

enum AgentSkillDraftingProviderError: LocalizedError {
    case invalidPrompt
    case disabledConfiguration
    case invalidConfiguration
    case unsupportedTool(AgentToolName)
    case invalidStreamEvent
    case responseEndedWithoutDraft
    case malformedDraft
    case invalidDraft
    case streamFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrompt:
            return "Describe the reusable Skill you want to draft."
        case .disabledConfiguration:
            return "AI Skill drafting is currently disabled."
        case .invalidConfiguration:
            return "The AI Skill drafting configuration is invalid."
        case .unsupportedTool(let tool):
            return "AI Skill drafting returned an unsupported tool: \(tool.rawValue)."
        case .invalidStreamEvent:
            return "AI Skill drafting returned an invalid stream event."
        case .responseEndedWithoutDraft:
            return "AI Skill drafting ended without producing a draft."
        case .malformedDraft:
            return "AI Skill drafting returned malformed Skill JSON."
        case .invalidDraft:
            return "AI Skill drafting returned an incomplete Skill."
        case .streamFailure(let detail):
            return detail
        }
    }
}
