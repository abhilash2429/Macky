import Foundation
import XCTest
@testable import Macky

final class AgentModelsTests: XCTestCase {
    func testFlatAgentConfigurationDecodesV1CapabilityFields() throws {
        let data = Data(
            #"""
            {
              "protocol_version": 1,
              "enabled": true,
              "development_only": true,
              "agent_id": "general",
              "display_name": "General Agent",
              "model": "sol-medium",
              "operations": ["general", "skill-draft"],
              "web_search": true,
              "tools": ["read_attachment", "run_javascript", "create_artifact", "ask_question", "final_result"]
            }
            """#.utf8
        )

        let configuration = try JSONDecoder().decode(AgentRemoteConfiguration.self, from: data)

        XCTAssertEqual(configuration.protocolVersion, 1)
        XCTAssertTrue(configuration.enabled)
        XCTAssertTrue(configuration.developmentOnly)
        XCTAssertEqual(configuration.agentID, "general")
        XCTAssertEqual(configuration.displayName, "General Agent")
        XCTAssertEqual(configuration.model, .solMedium)
        XCTAssertEqual(configuration.operations, [.general, .skillDraft])
        XCTAssertTrue(configuration.webSearch)
        XCTAssertEqual(
            configuration.tools,
            [.attachmentChunk, .runJavaScript, .artifact, .question, .finalResult]
        )
    }

    func testAgentResponseRequestEncodesOnlyV1ContinuationAndToolOutputFields() throws {
        let request = AgentResponseRequest(
            input: "Create a release-note draft.",
            webSearch: true,
            continuationItems: [
                .reasoning(id: "rs_1", encryptedContent: "encrypted-reasoning"),
                .message(id: "msg_1", text: "Checking the release notes"),
                .functionCall(
                    id: "fc_1",
                    callID: "call_1",
                    name: .runJavaScript,
                    arguments: #"{"source":"return input;","input_json":null}"#
                )
            ],
            toolOutputs: [
                AgentToolResponse(providerCallID: "call_1", output: #"{"result":true}"#)
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["protocol_version"] as? Int, 1)
        XCTAssertEqual(object["agent"] as? String, "general")
        XCTAssertEqual(object["operation"] as? String, "general")
        XCTAssertEqual(object["input"] as? String, "Create a release-note draft.")
        XCTAssertEqual(object["web_search"] as? Bool, true)
        XCTAssertNil(object["task"])
        XCTAssertNil(object["configuration"])
        XCTAssertNil(object["java_script_results"])

        let continuationItems = try XCTUnwrap(object["continuation_items"] as? [[String: Any]])
        XCTAssertEqual(continuationItems.count, 3)
        XCTAssertEqual(continuationItems[0]["type"] as? String, "reasoning")
        XCTAssertEqual(continuationItems[0]["encrypted_content"] as? String, "encrypted-reasoning")
        XCTAssertEqual(continuationItems[1]["type"] as? String, "message")
        XCTAssertEqual(continuationItems[1]["status"] as? String, "completed")
        XCTAssertEqual(continuationItems[1]["role"] as? String, "assistant")
        let messageContent = try XCTUnwrap(continuationItems[1]["content"] as? [[String: Any]])
        XCTAssertEqual(messageContent.first?["text"] as? String, "Checking the release notes")
        XCTAssertEqual(continuationItems[2]["type"] as? String, "function_call")
        XCTAssertEqual(continuationItems[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(continuationItems[2]["name"] as? String, "run_javascript")

        let toolOutputs = try XCTUnwrap(object["tool_outputs"] as? [[String: Any]])
        XCTAssertEqual(toolOutputs.count, 1)
        XCTAssertEqual(toolOutputs[0]["call_id"] as? String, "call_1")
        XCTAssertEqual(toolOutputs[0]["output"] as? String, #"{"result":true}"#)
    }

    func testNormalizedToolCallSSEDecodesRunJavaScriptWithItsFunctionContinuation() throws {
        let localToolCallID = UUID()
        let data = Data(
            """
            {
              "protocol_version": 1,
              "kind": "tool_call",
              "continuation_item": {
                "type": "function_call",
                "id": "fc_1",
                "call_id": "call_1",
                "name": "run_javascript",
                "arguments": "{\\\"source\\\":\\\"return input;\\\",\\\"input_json\\\":null}"
              },
              "tool_call": {
                "id": "\(localToolCallID.uuidString)",
                "provider_call_id": "call_1",
                "name": "run_javascript",
                "arguments": "{\\\"source\\\":\\\"return input;\\\",\\\"input_json\\\":null}"
              }
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(AgentResponseStreamEvent.self, from: data)

        XCTAssertEqual(event.kind, .toolCall)
        XCTAssertEqual(event.toolCall?.id, localToolCallID)
        XCTAssertEqual(event.toolCall?.providerCallID, "call_1")
        XCTAssertEqual(event.toolCall?.name, .runJavaScript)
        let javaScriptRequest = try XCTUnwrap(event.toolCall).decode(AgentRunJavaScriptRequest.self)
        XCTAssertEqual(javaScriptRequest.source, "return input;")
        XCTAssertNil(javaScriptRequest.inputJSON)

        guard case let .functionCall(id, callID, name, arguments)? = event.continuationItem else {
            return XCTFail("Expected a function-call continuation item.")
        }
        XCTAssertEqual(id, "fc_1")
        XCTAssertEqual(callID, "call_1")
        XCTAssertEqual(name, .runJavaScript)
        XCTAssertEqual(arguments, #"{"source":"return input;","input_json":null}"#)

        let encodedJavaScriptRequest = try JSONEncoder().encode(
            AgentRunJavaScriptRequest(source: "return input;", inputJSON: nil)
        )
        let javaScriptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedJavaScriptRequest) as? [String: Any]
        )
        XCTAssertEqual(javaScriptObject["source"] as? String, "return input;")
        XCTAssertTrue(javaScriptObject["input_json"] is NSNull)
    }

    func testNormalizedAssistantMessageSSEDecodesAsContinuation() throws {
        let data = Data(
            #"{"protocol_version":1,"kind":"continuation","continuation_item":{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Checking the sources"}]}}"#.utf8
        )

        let event = try JSONDecoder().decode(AgentResponseStreamEvent.self, from: data)

        guard case let .message(id, text)? = event.continuationItem else {
            return XCTFail("Expected an assistant message continuation item.")
        }
        XCTAssertEqual(id, "msg_1")
        XCTAssertEqual(text, "Checking the sources")
    }

    func testArtifactAndFinalResultToolArgumentsUseV1CodingKeys() throws {
        let artifact = AgentArtifactRequest(
            name: "notes.md",
            mediaType: "text/markdown",
            encoding: .utf8,
            content: Data("# Notes".utf8)
        )
        let artifactObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact)) as? [String: Any]
        )
        XCTAssertEqual(artifactObject["media_type"] as? String, "text/markdown")
        XCTAssertEqual(artifactObject["content"] as? String, "# Notes")

        let finalResult = AgentFinalResultRequest(
            spokenSummary: "I drafted the notes.",
            markdown: "# Notes",
            sources: [AgentFinalResultSource(title: "Docs", url: "https://example.com/docs")],
            artifactIDs: [UUID()],
            limitations: ["No release date was supplied."],
            suggestedActions: ["Review the draft."],
            partial: false
        )
        let finalResultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(finalResult)) as? [String: Any]
        )
        XCTAssertEqual(finalResultObject["spoken_summary"] as? String, "I drafted the notes.")
        XCTAssertEqual(finalResultObject["artifact_ids"] as? [String], finalResult.artifactIDs.map(\.uuidString))
        XCTAssertEqual(finalResultObject["suggested_actions"] as? [String], ["Review the draft."])
    }

    func testParentGroupRejectsMoreThanThreeJobs() {
        XCTAssertThrowsError(
            try AgentParentGroup(
                taskID: UUID(),
                jobIDs: [UUID(), UUID(), UUID(), UUID()]
            )
        )
    }

    func testTaskDecodesStateWrittenBeforeParentGroupsExisted() throws {
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Decode older local state",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any]
        )
        object.removeValue(forKey: "parentGroups")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decodedTask = try JSONDecoder().decode(AgentTask.self, from: legacyData)

        XCTAssertEqual(decodedTask.id, task.id)
        XCTAssertTrue(decodedTask.parentGroups.isEmpty)
    }

    func testQuestionExpiresExactlyAfterTwentyFourHours() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let question = AgentQuestion(
            taskID: UUID(),
            jobID: UUID(),
            attemptID: UUID(),
            prompt: "Which format should I use?",
            createdAt: createdAt
        )

        XCTAssertFalse(question.isExpired(at: createdAt.addingTimeInterval(AgentRetentionPolicy.questionLifetime - 1)))
        XCTAssertTrue(question.isExpired(at: createdAt.addingTimeInterval(AgentRetentionPolicy.questionLifetime)))
    }

    func testStoreAppendsIncreasingEventSequences() async throws {
        let persistence = AgentInMemoryPersistence()
        let store = AgentLocalStore(persistence: persistence)
        _ = try await store.load()

        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Summarize this",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await store.create(task: task, jobs: [job])
        let attempt = try await store.beginAttempt(for: job.id)
        _ = try await store.finalize(
            AgentFinalResultRequest(summary: "Done"),
            taskID: task.id,
            jobID: job.id,
            attemptID: attempt.id
        )

        let snapshot = await store.snapshot()
        let sequences = snapshot.events.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
    }

    func testRetentionDoesNotRefreshTerminalTaskActivityTimestamps() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AgentLocalStore(
            persistence: AgentInMemoryPersistence(),
            now: { fixedDate }
        )
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Expire this completed task",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: [],
            createdAt: fixedDate
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction, createdAt: fixedDate)
        try await store.create(task: task, jobs: [job])
        let attempt = try await store.beginAttempt(for: job.id)
        _ = try await store.finalize(
            AgentFinalResultRequest(summary: "Done"),
            taskID: task.id,
            jobID: job.id,
            attemptID: attempt.id
        )

        _ = try await store.enforceRetention(
            at: fixedDate.addingTimeInterval(AgentRetentionPolicy.historyLifetime + 1)
        )

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testQueuedCancellationDoesNotInventAnAttemptIdentifier() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Cancel before starting",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await store.create(task: task, jobs: [job])

        try await store.cancel(jobID: job.id)

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.attempts.isEmpty)
        XCTAssertNil(snapshot.results.first?.attemptID)
        XCTAssertEqual(snapshot.jobs.first?.status, .cancelled)
    }

    func testTerminalFailureCannotBeMutatedIntoCancellation() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Keep the original terminal outcome",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await store.create(task: task, jobs: [job])
        let attempt = try await store.beginAttempt(for: job.id)
        try await store.fail(jobID: job.id, attemptID: attempt.id, detail: "Provider failed")

        try await store.cancel(jobID: job.id, attemptID: attempt.id)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.status, .failed)
        XCTAssertEqual(snapshot.results.count, 1)
        XCTAssertEqual(snapshot.results.first?.status, .failed)
    }

    func testSteeringRemainsPendingUntilExplicitlyAcknowledged() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Apply steering safely",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await store.create(task: task, jobs: [job])
        try await store.queueSteering(taskID: task.id, text: "Use a table")

        let pendingSteering = try await store.pendingSteering(for: job.id)
        XCTAssertEqual(pendingSteering.map(\.text), ["Use a table"])

        try await store.markSteeringApplied(
            jobID: job.id,
            instructionIDs: Set(pendingSteering.map(\.id))
        )

        let remainingSteering = try await store.pendingSteering(for: job.id)
        XCTAssertTrue(remainingSteering.isEmpty)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.filter { $0.kind == .steeringApplied }.count, 1)
    }

    func testTaskSteeringIsQueuedForEveryActiveChildJob() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Investigate in parallel",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let jobs = [
            AgentJob(taskID: task.id, instruction: "Check the client"),
            AgentJob(taskID: task.id, instruction: "Check the Worker")
        ]
        try await store.create(task: task, jobs: jobs)

        try await store.queueSteering(taskID: task.id, text: "Include failure cases")

        for job in jobs {
            let pendingSteering = try await store.pendingSteering(for: job.id)
            XCTAssertEqual(pendingSteering.map(\.text), ["Include failure cases"])
        }
    }

    func testExecutionContextContainsOnlyTheCurrentChildJobThread() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Investigate in parallel",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let firstJob = AgentJob(taskID: task.id, instruction: "Check the client")
        let secondJob = AgentJob(taskID: task.id, instruction: "Check the Worker")
        try await store.create(task: task, jobs: [firstJob, secondJob])
        let firstAttempt = try await store.beginAttempt(for: firstJob.id)
        let secondAttempt = try await store.beginAttempt(for: secondJob.id)
        try await store.appendResponseText(
            taskID: task.id,
            jobID: firstJob.id,
            attemptID: firstAttempt.id,
            text: "Client progress"
        )
        try await store.appendResponseText(
            taskID: task.id,
            jobID: secondJob.id,
            attemptID: secondAttempt.id,
            text: "Worker progress"
        )

        let firstContext = try await store.executionContext(
            taskID: task.id,
            jobID: firstJob.id,
            attemptID: firstAttempt.id
        )

        XCTAssertTrue(firstContext.priorEvents.contains { $0.message == "Client progress" })
        XCTAssertFalse(firstContext.priorEvents.contains { $0.message == "Worker progress" })
    }

    func testArtifactCreationIsIdempotentForAProviderCall() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Create one artifact",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await store.create(task: task, jobs: [job])
        let attempt = try await store.beginAttempt(for: job.id)
        let request = AgentArtifactRequest(
            name: "summary.md",
            mediaType: "text/markdown",
            encoding: .utf8,
            content: Data("# Summary".utf8)
        )

        let firstArtifact = try await store.createArtifact(
            request,
            providerCallID: "call_artifact",
            taskID: task.id,
            jobID: job.id,
            attemptID: attempt.id
        )
        let replayedArtifact = try await store.createArtifact(
            request,
            providerCallID: "call_artifact",
            taskID: task.id,
            jobID: job.id,
            attemptID: attempt.id
        )

        let snapshot = await store.snapshot()
        XCTAssertEqual(replayedArtifact.id, firstArtifact.id)
        XCTAssertEqual(snapshot.artifacts.count, 1)
    }

    func testExplicitRestartClearsProviderContinuationState() async throws {
        let store = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await store.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Restart from a clean provider turn",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await store.create(task: task, jobs: [job])
        let attempt = try await store.beginAttempt(for: job.id)
        try await store.checkpoint(
            jobID: job.id,
            continuationItems: [
                .functionCall(
                    id: "fc_old",
                    callID: "call_old",
                    name: .runJavaScript,
                    arguments: #"{"source":"setResult(1);","input_json":null}"#
                )
            ],
            toolOutputs: [AgentToolResponse(providerCallID: "call_old", output: "1")]
        )
        try await store.fail(jobID: job.id, attemptID: attempt.id, detail: "Retry this task")

        _ = try await store.restart(taskID: task.id)

        let restartedJob = try await store.job(id: job.id)
        XCTAssertEqual(restartedJob.status, .queued)
        XCTAssertNil(restartedJob.continuationItems)
        XCTAssertNil(restartedJob.toolOutputs)
    }
}
