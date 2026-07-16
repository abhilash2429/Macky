import Foundation
import XCTest
@testable import Macky

final class AgentSkillDraftingProviderTests: XCTestCase {
    func testEmptyPromptIsRejectedBeforeConfigurationFetch() async {
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration()
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        do {
            _ = try await provider.draftSkill(for: "  \n\t ")
            XCTFail("Expected an empty prompt to be rejected.")
        } catch let error as AgentSkillDraftingProviderError {
            guard case .invalidPrompt = error else {
                return XCTFail("Expected invalidPrompt, received \(error).")
            }
        } catch {
            XCTFail("Expected AgentSkillDraftingProviderError, received \(error).")
        }

        let configurationFetchCount = await apiClient.configurationFetchCount()
        let recordedRequests = await apiClient.recordedRequests()
        XCTAssertEqual(configurationFetchCount, 0)
        XCTAssertEqual(recordedRequests.count, 0)
    }

    func testDisabledConfigurationIsRejected() async {
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration(enabled: false)
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        do {
            _ = try await provider.draftSkill(for: "Draft a meeting follow-up Skill.")
            XCTFail("Expected a disabled configuration to be rejected.")
        } catch let error as AgentSkillDraftingProviderError {
            guard case .disabledConfiguration = error else {
                return XCTFail("Expected disabledConfiguration, received \(error).")
            }
        } catch {
            XCTFail("Expected AgentSkillDraftingProviderError, received \(error).")
        }

        let recordedRequests = await apiClient.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
    }

    func testInvalidConfigurationIsRejected() async {
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration(tools: [.finalResult])
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        do {
            _ = try await provider.draftSkill(for: "Draft a meeting follow-up Skill.")
            XCTFail("Expected an invalid configuration to be rejected.")
        } catch let error as AgentSkillDraftingProviderError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected invalidConfiguration, received \(error).")
            }
        } catch {
            XCTFail("Expected AgentSkillDraftingProviderError, received \(error).")
        }

        let recordedRequests = await apiClient.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
    }

    func testSuccessfulFinalResultStrictlyDecodesSkillDraftJSON() async throws {
        let markdown = #"{"name":"Meeting Follow-up","description":"Turns meeting notes into follow-up tasks.","instructions":"Review the notes, identify owners and due dates, then draft concise follow-up tasks.","compatible_agent_types":["general","planner"]}"#
        let finalResultEvent = try makeFinalResultEvent(markdown: markdown)
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration(),
            responseEvents: [
                AgentResponseStreamEvent(kind: .text, text: "I will draft that."),
                finalResultEvent
            ]
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        let draft = try await provider.draftSkill(for: "Create a Skill for meeting follow-up.")

        XCTAssertEqual(draft.name, "Meeting Follow-up")
        XCTAssertEqual(draft.description, "Turns meeting notes into follow-up tasks.")
        XCTAssertEqual(
            draft.instructions,
            "Review the notes, identify owners and due dates, then draft concise follow-up tasks."
        )
        XCTAssertEqual(draft.compatibleAgentTypes, ["general", "planner"])
        XCTAssertEqual(draft.origin, .aiDraft)

        let requests = await apiClient.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.agent, AgentRegistry.general.id)
        XCTAssertEqual(requests.first?.operation, .skillDraft)
        XCTAssertFalse(requests.first?.webSearch ?? true)
        XCTAssertTrue(requests.first?.input.contains("Create a Skill for meeting follow-up.") ?? false)
    }

    func testUnsupportedToolIsRejected() async throws {
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration(),
            responseEvents: [makeToolCallEvent(name: .question)]
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        do {
            _ = try await provider.draftSkill(for: "Draft a Skill for organizing tasks.")
            XCTFail("Expected an unsupported tool to be rejected.")
        } catch let error as AgentSkillDraftingProviderError {
            guard case .unsupportedTool(.question) = error else {
                return XCTFail("Expected unsupportedTool(.question), received \(error).")
            }
        } catch {
            XCTFail("Expected AgentSkillDraftingProviderError, received \(error).")
        }
    }

    func testMalformedFinalResultJSONIsRejected() async throws {
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration(),
            responseEvents: [try makeFinalResultEvent(markdown: "{not valid JSON")]
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        do {
            _ = try await provider.draftSkill(for: "Draft a Skill for organizing tasks.")
            XCTFail("Expected malformed Skill JSON to be rejected.")
        } catch let error as AgentSkillDraftingProviderError {
            guard case .malformedDraft = error else {
                return XCTFail("Expected malformedDraft, received \(error).")
            }
        } catch {
            XCTFail("Expected AgentSkillDraftingProviderError, received \(error).")
        }
    }

    func testCompletedEventWithoutDraftIsRejected() async {
        let apiClient = AgentSkillDraftingProviderMockAPIClient(
            configuration: makeConfiguration(),
            responseEvents: [AgentResponseStreamEvent(kind: .completed)]
        )
        let provider = AgentSkillDraftingProvider(apiClient: apiClient)

        do {
            _ = try await provider.draftSkill(for: "Draft a Skill for organizing tasks.")
            XCTFail("Expected completion without a draft to be rejected.")
        } catch let error as AgentSkillDraftingProviderError {
            guard case .responseEndedWithoutDraft = error else {
                return XCTFail("Expected responseEndedWithoutDraft, received \(error).")
            }
        } catch {
            XCTFail("Expected AgentSkillDraftingProviderError, received \(error).")
        }
    }
}

private actor AgentSkillDraftingProviderMockAPIClient: AgentAPIServing {
    private let configuration: AgentRemoteConfiguration
    private let responseEvents: [AgentResponseStreamEvent]
    private var configurationFetches = 0
    private var requests: [AgentResponseRequest] = []

    init(
        configuration: AgentRemoteConfiguration,
        responseEvents: [AgentResponseStreamEvent] = []
    ) {
        self.configuration = configuration
        self.responseEvents = responseEvents
    }

    func fetchConfiguration(for definition: AgentDefinition) async throws -> AgentRemoteConfiguration {
        configurationFetches += 1
        return configuration
    }

    func streamResponse(
        _ request: AgentResponseRequest
    ) async -> AsyncThrowingStream<AgentResponseStreamEvent, Error> {
        requests.append(request)
        let responseEvents = self.responseEvents
        return AsyncThrowingStream { continuation in
            for event in responseEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func configurationFetchCount() -> Int {
        configurationFetches
    }

    func recordedRequests() -> [AgentResponseRequest] {
        requests
    }
}

private func makeConfiguration(
    enabled: Bool = true,
    developmentOnly: Bool = true,
    operations: [AgentOperation] = [.general, .skillDraft],
    tools: [AgentToolName] = AgentRegistry.general.toolContracts.map(\.name)
) -> AgentRemoteConfiguration {
    AgentRemoteConfiguration(
        enabled: enabled,
        developmentOnly: developmentOnly,
        agentID: AgentRegistry.general.id,
        displayName: AgentRegistry.general.displayName,
        model: AgentRegistry.general.model,
        operations: operations,
        webSearch: false,
        tools: tools
    )
}

private func makeToolCallEvent(
    name: AgentToolName,
    arguments: String = "{}"
) -> AgentResponseStreamEvent {
    let toolCall = AgentToolCall(
        providerCallID: "call_\(name.rawValue)",
        name: name,
        arguments: arguments
    )
    return AgentResponseStreamEvent(
        kind: .toolCall,
        continuationItem: .functionCall(
            id: "function_\(name.rawValue)",
            callID: toolCall.providerCallID,
            name: toolCall.name,
            arguments: toolCall.arguments
        ),
        toolCall: toolCall
    )
}

private func makeFinalResultEvent(markdown: String) throws -> AgentResponseStreamEvent {
    let finalResult = AgentFinalResultRequest(
        spokenSummary: "The Skill draft is ready.",
        markdown: markdown,
        sources: [],
        artifactIDs: [],
        limitations: [],
        suggestedActions: [],
        partial: false
    )
    let arguments = String(
        decoding: try JSONEncoder().encode(finalResult),
        as: UTF8.self
    )
    return makeToolCallEvent(name: .finalResult, arguments: arguments)
}
