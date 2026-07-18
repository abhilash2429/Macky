import Foundation
import XCTest
@testable import Macky

final class AgentRuntimeTests: XCTestCase {
    func testRelaunchQueuesPreviouslyRunningWork() async throws {
        let persistence = AgentInMemoryPersistence()
        let localStore = AgentLocalStore(persistence: persistence)
        _ = try await localStore.load()

        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Continue after relaunch",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await localStore.create(task: task, jobs: [job])
        let attempt = try await localStore.beginAttempt(for: job.id)

        let recoveredJobIDs = try await localStore.preparePersistedWorkForRelaunch()
        let snapshot = await localStore.snapshot()

        XCTAssertEqual(recoveredJobIDs, [job.id])
        XCTAssertEqual(snapshot.jobs.first?.status, .queued)
        XCTAssertEqual(snapshot.attempts.first(where: { $0.id == attempt.id })?.status, .interrupted)
    }

    func testLifecyclePauseInterruptsAttemptButKeepsJobQueued() async throws {
        let localStore = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await localStore.load()
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Resume after wake",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        try await localStore.create(task: task, jobs: [job])
        let attempt = try await localStore.beginAttempt(for: job.id)

        try await localStore.queueAfterLifecycleInterruption(
            jobID: job.id,
            attemptID: attempt.id,
            detail: "Mac sleep paused this task"
        )
        let snapshot = await localStore.snapshot()

        XCTAssertEqual(snapshot.tasks.first?.status, .queued)
        XCTAssertEqual(snapshot.jobs.first?.status, .queued)
        XCTAssertEqual(snapshot.attempts.first?.status, .interrupted)
    }

    func testRuntimeFinalizesAJobFromTheFinalResultContract() async throws {
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Produce a brief result",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        let finalResult = AgentFinalResultRequest(summary: "Completed locally")
        let finalResultArguments = try String(
            decoding: JSONEncoder().encode(finalResult),
            as: UTF8.self
        )
        let finalToolCall = AgentToolCall(
            providerCallID: "call_final",
            name: .finalResult,
            arguments: finalResultArguments
        )
        let configuration = AgentRemoteConfiguration(
            enabled: true,
            developmentOnly: true,
            agentID: AgentRegistry.general.id,
            displayName: AgentRegistry.general.displayName,
            model: .solMedium,
            operations: [.general, .skillDraft],
            webSearch: true,
            tools: AgentToolContract.generalAgentContracts.map(\.name)
        )
        let apiClient = AgentFakeAPIClient(
            configuration: configuration,
            responseBatches: [[
                AgentResponseStreamEvent(kind: .text, text: "Preparing"),
                AgentResponseStreamEvent(kind: .text, text: " "),
                AgentResponseStreamEvent(kind: .text, text: "result"),
                AgentResponseStreamEvent(
                    kind: .toolCall,
                    continuationItem: .functionCall(
                        id: "fc_final",
                        callID: finalToolCall.providerCallID,
                        name: finalToolCall.name,
                        arguments: finalToolCall.arguments
                    ),
                    toolCall: finalToolCall
                ),
            ]]
        )
        let persistence = AgentInMemoryPersistence()
        let localStore = AgentLocalStore(persistence: persistence)
        _ = try await localStore.load()
        try await localStore.create(task: task, jobs: [job])
        let attachmentStore = AgentAttachmentStore(
            rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let javascriptExecutor = await MainActor.run { AgentUnavailableJavaScriptExecutor() }
        let runtime = AgentRuntime(
            store: localStore,
            apiClient: apiClient,
            attachmentStore: attachmentStore,
            javaScriptExecutor: javascriptExecutor
        )

        await runtime.enqueue(jobIDs: [job.id])
        for _ in 0..<100 {
            let currentSnapshot = await localStore.snapshot()
            if currentSnapshot.tasks.first?.status == .completed {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let snapshot = await localStore.snapshot()
        let requestCount = await apiClient.requests().count
        XCTAssertEqual(snapshot.tasks.first?.status, .completed)
        XCTAssertEqual(snapshot.results.first?.summary, "Completed locally")
        XCTAssertEqual(
            snapshot.events.first(where: { $0.kind == .responseTextReceived })?.message,
            "Preparing result"
        )
        XCTAssertEqual(requestCount, 1)
    }

    func testRuntimeReplaysCheckpointedLocalToolCallBeforeProviderContinuation() async throws {
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Resume local calculation",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        let localCallID = "call_local_resume"
        let localArguments = #"{"source":"setResult({value: input.value * 2});","input_json":"{\"value\":21}"}"#
        let finalResult = AgentFinalResultRequest(summary: "Resumed and completed")
        let finalToolCall = AgentToolCall(
            providerCallID: "call_final_after_resume",
            name: .finalResult,
            arguments: try String(decoding: JSONEncoder().encode(finalResult), as: UTF8.self)
        )
        let configuration = AgentRemoteConfiguration(
            enabled: true,
            developmentOnly: true,
            agentID: AgentRegistry.general.id,
            displayName: AgentRegistry.general.displayName,
            model: .solMedium,
            operations: [.general, .skillDraft],
            webSearch: true,
            tools: AgentToolContract.generalAgentContracts.map(\.name)
        )
        let apiClient = AgentFakeAPIClient(
            configuration: configuration,
            responseBatches: [[AgentResponseStreamEvent(
                kind: .toolCall,
                continuationItem: .functionCall(
                    id: "fc_final_after_resume",
                    callID: finalToolCall.providerCallID,
                    name: finalToolCall.name,
                    arguments: finalToolCall.arguments
                ),
                toolCall: finalToolCall
            )]]
        )
        let localStore = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await localStore.load()
        try await localStore.create(task: task, jobs: [job])
        try await localStore.checkpoint(
            jobID: job.id,
            continuationItems: [
                .functionCall(
                    id: "fc_local_resume",
                    callID: localCallID,
                    name: .runJavaScript,
                    arguments: localArguments
                )
            ],
            toolOutputs: []
        )
        let javaScriptExecutor = await MainActor.run {
            AgentFakeJavaScriptExecutor(
                result: AgentJavaScriptExecutionResult(
                    output: Data(#"{"result":{"value":42},"artifacts":[]}"#.utf8)
                )
            )
        }
        let runtime = AgentRuntime(
            store: localStore,
            apiClient: apiClient,
            attachmentStore: AgentAttachmentStore(
                rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            javaScriptExecutor: javaScriptExecutor
        )

        await runtime.enqueue(jobIDs: [job.id])
        for _ in 0..<100 {
            let currentSnapshot = await localStore.snapshot()
            if currentSnapshot.tasks.first?.status == .completed {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let snapshot = await localStore.snapshot()
        let requests = await apiClient.requests()
        let executedRequests = await MainActor.run { javaScriptExecutor.executedRequests() }
        XCTAssertEqual(snapshot.tasks.first?.status, .completed)
        XCTAssertEqual(executedRequests.count, 1)
        XCTAssertEqual(requests.first?.toolOutputs.first?.providerCallID, localCallID)
        XCTAssertTrue(requests.first?.toolOutputs.first?.output.contains("42") ?? false)
    }

    func testRuntimeRetriesATransientStreamFailureBeforeAnyOutput() async throws {
        let task = AgentTask(
            agentID: AgentRegistry.general.id,
            instruction: "Retry one transient failure",
            source: AgentSource(kind: .text),
            skillSnapshots: [],
            attachments: []
        )
        let job = AgentJob(taskID: task.id, instruction: task.instruction)
        let finalResult = AgentFinalResultRequest(summary: "Completed after retry")
        let finalToolCall = AgentToolCall(
            providerCallID: "call_final_after_retry",
            name: .finalResult,
            arguments: try String(decoding: JSONEncoder().encode(finalResult), as: UTF8.self)
        )
        let apiClient = RetryingAgentAPIClient(
            failuresBeforeSuccess: 1,
            successfulEvents: [AgentResponseStreamEvent(
                kind: .toolCall,
                continuationItem: .functionCall(
                    id: "fc_final_after_retry",
                    callID: finalToolCall.providerCallID,
                    name: finalToolCall.name,
                    arguments: finalToolCall.arguments
                ),
                toolCall: finalToolCall
            )]
        )
        let localStore = AgentLocalStore(persistence: AgentInMemoryPersistence())
        _ = try await localStore.load()
        try await localStore.create(task: task, jobs: [job])
        let javaScriptExecutor = await MainActor.run { AgentUnavailableJavaScriptExecutor() }
        let runtime = AgentRuntime(
            store: localStore,
            apiClient: apiClient,
            attachmentStore: AgentAttachmentStore(
                rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            javaScriptExecutor: javaScriptExecutor
        )

        await runtime.enqueue(jobIDs: [job.id])
        for _ in 0..<400 {
            let currentSnapshot = await localStore.snapshot()
            if currentSnapshot.tasks.first?.status == .completed {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let snapshot = await localStore.snapshot()
        let streamAttemptCount = await apiClient.streamAttemptCount()
        XCTAssertEqual(snapshot.tasks.first?.status, .completed)
        XCTAssertEqual(streamAttemptCount, 2)
    }
}

private actor RetryingAgentAPIClient: AgentAPIServing {
    private let failuresBeforeSuccess: Int
    private let successfulEvents: [AgentResponseStreamEvent]
    private var attempts = 0

    init(failuresBeforeSuccess: Int, successfulEvents: [AgentResponseStreamEvent]) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.successfulEvents = successfulEvents
    }

    func fetchConfiguration(for definition: AgentDefinition) async throws -> AgentRemoteConfiguration {
        AgentRemoteConfiguration(
            enabled: true,
            developmentOnly: true,
            agentID: definition.id,
            displayName: definition.displayName,
            model: definition.model,
            operations: [.general, .skillDraft],
            webSearch: true,
            tools: definition.toolContracts.map(\.name)
        )
    }

    func streamResponse(
        _ request: AgentResponseRequest
    ) async -> AsyncThrowingStream<AgentResponseStreamEvent, Error> {
        _ = request
        attempts += 1
        let shouldFail = attempts <= failuresBeforeSuccess
        let events = successfulEvents
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: URLError(.timedOut))
                return
            }
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func streamAttemptCount() -> Int {
        attempts
    }
}
