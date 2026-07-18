//
//  AgentRuntime.swift
//  leanring-buddy
//

import Foundation

/// Schedules General Agent jobs with three active executions and an intentionally
/// unbounded pending queue. It contains no task-duration, search, usage, or turn cap.
actor AgentRuntime {
    static let maximumConcurrentJobs = 3
    private static let responseTextFlushByteCount = 1_024
    private static let maximumTransientResponseRetries = 2

    private let store: AgentLocalStore
    private let apiClient: AgentAPIServing
    private let attachmentStore: AgentAttachmentAccessing
    private let javaScriptExecutor: AgentJavaScriptExecuting
    private let definitions: [String: AgentDefinition]

    private var queuedJobIDs: [UUID] = []
    private var activeJobTasks: [UUID: Task<Void, Never>] = [:]
    private var requestedCancellationJobIDs = Set<UUID>()
    private var isStopping = false
    private var isPausedForSystemSleep = false

    init(
        store: AgentLocalStore,
        apiClient: AgentAPIServing,
        attachmentStore: AgentAttachmentAccessing,
        javaScriptExecutor: AgentJavaScriptExecuting,
        definitions: [AgentDefinition] = AgentRegistry.registeredAgents
    ) {
        self.store = store
        self.apiClient = apiClient
        self.attachmentStore = attachmentStore
        self.javaScriptExecutor = javaScriptExecutor
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    }

    func enqueue(jobIDs: [UUID]) async {
        guard !isStopping else { return }
        for jobID in jobIDs where !queuedJobIDs.contains(jobID) && activeJobTasks[jobID] == nil {
            queuedJobIDs.append(jobID)
        }
        guard !isPausedForSystemSleep else { return }
        scheduleIfPossible()
    }

    func stop() async {
        isStopping = true
        queuedJobIDs.removeAll()
        let runningTasks = Array(activeJobTasks.values)
        for runningTask in runningTasks {
            runningTask.cancel()
        }
        for runningTask in runningTasks {
            await runningTask.value
        }
    }

    func pauseForSystemSleep() async -> [UUID] {
        guard !isStopping, !isPausedForSystemSleep else { return [] }
        isPausedForSystemSleep = true
        let pausedJobIDs = Array(Set(queuedJobIDs + Array(activeJobTasks.keys)))
        queuedJobIDs.removeAll()
        let runningTasks = Array(activeJobTasks.values)
        for runningTask in runningTasks {
            runningTask.cancel()
        }
        for runningTask in runningTasks {
            await runningTask.value
        }
        return pausedJobIDs
    }

    func resumeAfterSystemWake(jobIDs: [UUID]) async {
        guard !isStopping else { return }
        isPausedForSystemSleep = false
        await enqueue(jobIDs: jobIDs)
    }

    func cancel(taskID: UUID) async throws {
        let jobs = await store.jobs(for: taskID)
        guard !jobs.isEmpty else { throw AgentRuntimeError.missingTask(taskID) }
        let cancellableJobs = jobs.filter { [.queued, .running, .waiting].contains($0.status) }
        guard !cancellableJobs.isEmpty else { throw AgentRuntimeError.taskNotCancellable }
        for job in cancellableJobs {
            queuedJobIDs.removeAll { $0 == job.id }
            if activeJobTasks[job.id] != nil {
                requestedCancellationJobIDs.insert(job.id)
                try await store.recordCancellationRequested(jobID: job.id)
                activeJobTasks[job.id]?.cancel()
            } else {
                try await store.cancel(jobID: job.id)
            }
        }
        scheduleIfPossible()
    }

    func restart(taskID: UUID) async throws {
        let jobIDs = try await store.restart(taskID: taskID)
        await enqueue(jobIDs: jobIDs)
    }

    func answer(questionID: UUID, answer: String) async throws {
        let jobID = try await store.answerQuestion(id: questionID, answer: answer)
        await enqueue(jobIDs: [jobID])
    }

    func steer(taskID: UUID, text: String) async throws {
        try await store.queueSteering(taskID: taskID, text: text)
    }

    func activeJobCount() -> Int {
        activeJobTasks.count
    }

    private func scheduleIfPossible() {
        guard !isStopping, !isPausedForSystemSleep else { return }
        while activeJobTasks.count < Self.maximumConcurrentJobs, !queuedJobIDs.isEmpty {
            let jobID = queuedJobIDs.removeFirst()
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.run(jobID: jobID)
            }
            activeJobTasks[jobID] = task
        }
    }

    private func run(jobID: UUID) async {
        var attemptID: UUID?
        do {
            try Task.checkCancellation()
            let job = try await store.job(id: jobID)
            guard job.status == .queued else {
                release(jobID: jobID)
                return
            }
            let attempt = try await store.beginAttempt(for: jobID)
            attemptID = attempt.id
            try await runAttempt(jobID: jobID, attemptID: attempt.id)
        } catch is CancellationError {
            if requestedCancellationJobIDs.remove(jobID) != nil {
                try? await store.cancel(jobID: jobID, attemptID: attemptID)
            } else if isStopping || isPausedForSystemSleep {
                try? await store.queueAfterLifecycleInterruption(
                    jobID: jobID,
                    attemptID: attemptID,
                    detail: isStopping
                        ? "Macky closed before this task finished"
                        : "Mac sleep paused this task"
                )
            } else {
                try? await store.cancel(jobID: jobID, attemptID: attemptID)
            }
        } catch {
            if Task.isCancelled, requestedCancellationJobIDs.remove(jobID) != nil {
                try? await store.cancel(jobID: jobID, attemptID: attemptID)
            } else if Task.isCancelled, isStopping || isPausedForSystemSleep {
                try? await store.queueAfterLifecycleInterruption(
                    jobID: jobID,
                    attemptID: attemptID,
                    detail: isStopping
                        ? "Macky closed before this task finished"
                        : "Mac sleep paused this task"
                )
            } else if Task.isCancelled {
                try? await store.cancel(jobID: jobID, attemptID: attemptID)
            } else if requestedCancellationJobIDs.remove(jobID) != nil {
                try? await store.cancel(jobID: jobID, attemptID: attemptID)
            } else {
                try? await store.fail(jobID: jobID, attemptID: attemptID, detail: error.localizedDescription)
            }
        }
        release(jobID: jobID)
    }

    private func release(jobID: UUID) {
        requestedCancellationJobIDs.remove(jobID)
        activeJobTasks.removeValue(forKey: jobID)
        scheduleIfPossible()
    }

    private func runAttempt(jobID: UUID, attemptID: UUID) async throws {
        let initialContext = try await context(jobID: jobID, attemptID: attemptID)
        guard let definition = definitions[initialContext.task.agentID] else {
            throw AgentRuntimeError.unknownAgent(initialContext.task.agentID)
        }
        let configuration = try await fetchConfiguration(for: definition)
        try validate(configuration: configuration, for: definition)

        var continuationItems = initialContext.job.continuationItems ?? []
        var toolOutputs = initialContext.job.toolOutputs ?? []
        var steeringInstructions = try await store.pendingSteering(for: jobID)
        var runtimeGuidance: [String] = []
        var previousToolSignature: String?
        var repeatedToolCount = 0
        var completionWithoutFinalCount = 0
        var transientResponseRetryCount = 0

        if requestedCancellationJobIDs.remove(jobID) != nil {
            try await store.cancel(jobID: jobID, attemptID: attemptID)
            return
        }
        if let unresolvedToolCall = Self.unresolvedToolCall(
            continuationItems: continuationItems,
            toolOutputs: toolOutputs
        ) {
            try Task.checkCancellation()
            let executionContext = try await context(jobID: jobID, attemptID: attemptID)
            try Task.checkCancellation()
            if requestedCancellationJobIDs.remove(jobID) != nil {
                try await store.cancel(jobID: jobID, attemptID: attemptID)
                return
            }
            let disposition: AgentToolDisposition
            if unresolvedToolCall.name == .finalResult, !steeringInstructions.isEmpty {
                disposition = .response(
                    AgentToolResponse(
                        providerCallID: unresolvedToolCall.providerCallID,
                        output: "{\"accepted\":false,\"reason\":\"New user steering arrived before finalization. Revise the result.\"}"
                    )
                )
            } else {
                disposition = try await handle(toolCall: unresolvedToolCall, context: executionContext)
            }
            switch disposition {
            case .response(let response):
                toolOutputs.removeAll { $0.providerCallID == response.providerCallID }
                toolOutputs.append(response)
                try await store.checkpoint(
                    jobID: jobID,
                    continuationItems: continuationItems,
                    toolOutputs: toolOutputs
                )
            case .waiting, .finished:
                return
            }
        }

        while true {
            try Task.checkCancellation()
            if requestedCancellationJobIDs.remove(jobID) != nil {
                try await store.cancel(jobID: jobID, attemptID: attemptID)
                return
            }
            Self.appendUniqueSteering(
                try await store.pendingSteering(for: jobID),
                to: &steeringInstructions
            )
            let executionContext = try await context(jobID: jobID, attemptID: attemptID)
            let request = AgentResponseRequest(
                agent: definition.id,
                input: Self.makeInput(
                    context: executionContext,
                    steeringInstructions: steeringInstructions,
                    runtimeGuidance: runtimeGuidance
                ),
                webSearch: configuration.webSearch,
                continuationItems: continuationItems,
                toolOutputs: toolOutputs
            )
            runtimeGuidance = []
            let stream = await apiClient.streamResponse(request)
            var shouldRequestFollowup = false
            var responseCompleted = false
            var bufferedResponseText = ""
            let steeringInstructionIDs = Set(steeringInstructions.map(\.id))
            var didAcknowledgeSteering = steeringInstructionIDs.isEmpty

            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    if !didAcknowledgeSteering, event.kind != .error {
                        try await store.markSteeringApplied(
                            jobID: jobID,
                            instructionIDs: steeringInstructionIDs
                        )
                        steeringInstructions = []
                        didAcknowledgeSteering = true
                    }
                    switch event.kind {
                case .text:
                    if let text = event.text, !text.isEmpty {
                        bufferedResponseText += text
                        if bufferedResponseText.utf8.count >= Self.responseTextFlushByteCount
                            || bufferedResponseText.contains("\n") {
                            try await store.appendResponseText(
                                taskID: executionContext.task.id,
                                jobID: jobID,
                                attemptID: attemptID,
                                text: bufferedResponseText
                            )
                            bufferedResponseText = ""
                        }
                    }

                case .continuation:
                    guard let continuationItem = event.continuationItem else {
                        throw AgentRuntimeError.invalidToolCall
                    }
                    Self.appendUnique(continuationItem, to: &continuationItems)

                case .toolCall:
                    if !bufferedResponseText.isEmpty {
                        try await store.appendResponseText(
                            taskID: executionContext.task.id,
                            jobID: jobID,
                            attemptID: attemptID,
                            text: bufferedResponseText
                        )
                        bufferedResponseText = ""
                    }
                    guard let toolCall = event.toolCall,
                          let continuationItem = event.continuationItem else {
                        throw AgentRuntimeError.invalidToolCall
                    }
                    Self.appendUnique(continuationItem, to: &continuationItems)
                    let toolSignature = "\(toolCall.name.rawValue):\(toolCall.arguments)"
                    if toolSignature == previousToolSignature {
                        repeatedToolCount += 1
                    } else {
                        previousToolSignature = toolSignature
                        repeatedToolCount = 1
                    }
                    guard repeatedToolCount < 3 else {
                        throw AgentRuntimeError.noProgress
                    }
                    try await store.recordToolRequest(
                        toolCall,
                        taskID: executionContext.task.id,
                        jobID: jobID,
                        attemptID: attemptID
                    )
                    try await store.checkpoint(
                        jobID: jobID,
                        continuationItems: continuationItems,
                        toolOutputs: toolOutputs
                    )
                    if requestedCancellationJobIDs.remove(jobID) != nil {
                        try await store.cancel(jobID: jobID, attemptID: attemptID)
                        return
                    }
                    let pendingSteeringBeforeTool = try await store.pendingSteering(for: jobID)
                    if !pendingSteeringBeforeTool.isEmpty {
                        let rejectedToolCall = AgentToolResponse(
                            providerCallID: toolCall.providerCallID,
                            output: "{\"accepted\":false,\"reason\":\"New user steering arrived before this step. Reconsider the task before calling another tool.\"}"
                        )
                        toolOutputs.removeAll { $0.providerCallID == rejectedToolCall.providerCallID }
                        toolOutputs.append(rejectedToolCall)
                        try await store.checkpoint(
                            jobID: jobID,
                            continuationItems: continuationItems,
                            toolOutputs: toolOutputs
                        )
                        shouldRequestFollowup = true
                        break
                    }
                    switch try await handle(
                        toolCall: toolCall,
                        context: executionContext
                    ) {
                    case .response(let response):
                        completionWithoutFinalCount = 0
                        toolOutputs.removeAll { $0.providerCallID == response.providerCallID }
                        toolOutputs.append(response)
                        try await store.checkpoint(
                            jobID: jobID,
                            continuationItems: continuationItems,
                            toolOutputs: toolOutputs
                        )
                        shouldRequestFollowup = true
                    case .waiting, .finished:
                        return
                    }

                case .completed:
                    if !bufferedResponseText.isEmpty {
                        try await store.appendResponseText(
                            taskID: executionContext.task.id,
                            jobID: jobID,
                            attemptID: attemptID,
                            text: bufferedResponseText
                        )
                        bufferedResponseText = ""
                    }
                    if requestedCancellationJobIDs.remove(jobID) != nil {
                        try await store.cancel(jobID: jobID, attemptID: attemptID)
                        return
                    }
                    responseCompleted = true

                case .error:
                    if !bufferedResponseText.isEmpty {
                        try await store.appendResponseText(
                            taskID: executionContext.task.id,
                            jobID: jobID,
                            attemptID: attemptID,
                            text: bufferedResponseText
                        )
                        bufferedResponseText = ""
                    }
                    throw AgentRuntimeError.remoteResponseUnavailable
                    }

                    if shouldRequestFollowup { break }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !bufferedResponseText.isEmpty {
                    try await store.appendResponseText(
                        taskID: executionContext.task.id,
                        jobID: jobID,
                        attemptID: attemptID,
                        text: bufferedResponseText
                    )
                    bufferedResponseText = ""
                }
                if transientResponseRetryCount < Self.maximumTransientResponseRetries,
                   Self.isTransientResponseFailure(error) {
                    transientResponseRetryCount += 1
                    runtimeGuidance = [
                        "The previous provider connection ended before returning task output. Retry the same work without claiming it completed."
                    ]
                    try await Task.sleep(for: .seconds(transientResponseRetryCount))
                    continue
                }
                throw error
            }

            // URLSession cancellation can finish an AsyncThrowingStream without
            // surfacing CancellationError to its consumer. Re-check here so sleep
            // and app shutdown queue the job for recovery instead of marking it failed.
            try Task.checkCancellation()
            if !bufferedResponseText.isEmpty {
                try await store.appendResponseText(
                    taskID: executionContext.task.id,
                    jobID: jobID,
                    attemptID: attemptID,
                    text: bufferedResponseText
                )
            }
            if shouldRequestFollowup {
                transientResponseRetryCount = 0
                continue
            }
            if responseCompleted {
                transientResponseRetryCount = 0
                completionWithoutFinalCount += 1
                guard completionWithoutFinalCount < 3 else {
                    throw AgentRuntimeError.noProgress
                }
                runtimeGuidance = [
                    "The previous response ended without calling final_result. Continue the task and finish only through final_result."
                ]
                continue
            }
            if transientResponseRetryCount < Self.maximumTransientResponseRetries {
                transientResponseRetryCount += 1
                runtimeGuidance = [
                    "The previous provider stream closed before returning task output. Retry the same work without claiming it completed."
                ]
                try await Task.sleep(for: .seconds(transientResponseRetryCount))
                continue
            }
            throw AgentRuntimeError.responseEndedWithoutResult
        }
    }

    private func context(jobID: UUID, attemptID: UUID) async throws -> AgentExecutionContext {
        let job = try await store.job(id: jobID)
        return try await store.executionContext(
            taskID: job.taskID,
            jobID: jobID,
            attemptID: attemptID
        )
    }

    private func fetchConfiguration(for definition: AgentDefinition) async throws -> AgentRemoteConfiguration {
        var retryCount = 0
        while true {
            do {
                return try await apiClient.fetchConfiguration(for: definition)
            } catch {
                guard retryCount < Self.maximumTransientResponseRetries,
                      Self.isTransientResponseFailure(error) else {
                    throw error
                }
                retryCount += 1
                try await Task.sleep(for: .seconds(retryCount))
            }
        }
    }

    private func validate(configuration: AgentRemoteConfiguration, for definition: AgentDefinition) throws {
        guard configuration.enabled,
              configuration.developmentOnly,
              configuration.agentID == definition.id,
              configuration.model == definition.model,
              configuration.operations.contains(.general) else {
            throw AgentRuntimeError.invalidRemoteConfiguration
        }
        let allowedTools = Set(definition.toolContracts.map(\.name))
        let configuredTools = Set(configuration.tools)
        guard configuredTools == allowedTools else {
            throw AgentRuntimeError.unsafeRemoteConfiguration
        }
    }

    private func handle(
        toolCall: AgentToolCall,
        context: AgentExecutionContext
    ) async throws -> AgentToolDisposition {
        switch toolCall.name {
        case .attachmentChunk:
            let request: AgentAttachmentChunkRequest = try decode(toolCall, as: AgentAttachmentChunkRequest.self)
            let chunk = try await attachmentStore.chunk(for: request, in: context.task)
            try await store.recordAttachmentChunk(
                chunk,
                taskID: context.task.id,
                jobID: context.job.id,
                attemptID: context.attempt.id
            )
            return .response(try AgentToolResponse(
                providerCallID: toolCall.providerCallID,
                payload: chunk
            ))

        case .runJavaScript:
            let request: AgentRunJavaScriptRequest = try decode(toolCall, as: AgentRunJavaScriptRequest.self)
            let trimmedSource = request.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty else { throw AgentRuntimeError.invalidToolCall }
            let inputData = request.inputJSON.map { Data($0.utf8) }
            let result = try await javaScriptExecutor.execute(
                AgentJavaScriptExecutionRequest(source: request.source, input: inputData)
            )
            guard let output = String(data: result.output, encoding: .utf8) else {
                throw AgentRuntimeError.invalidToolCall
            }
            return .response(
                AgentToolResponse(providerCallID: toolCall.providerCallID, output: output)
            )

        case .artifact:
            let request: AgentArtifactRequest = try decode(toolCall, as: AgentArtifactRequest.self)
            guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentRuntimeError.invalidToolCall
            }
            let artifact = try await store.createArtifact(
                request,
                providerCallID: toolCall.providerCallID,
                taskID: context.task.id,
                jobID: context.job.id,
                attemptID: context.attempt.id
            )
            return .response(try AgentToolResponse(
                providerCallID: toolCall.providerCallID,
                payload: [
                    "artifact_id": artifact.id.uuidString,
                    "name": artifact.name,
                    "media_type": artifact.mediaType
                ]
            ))

        case .question:
            let request: AgentQuestionRequest = try decode(toolCall, as: AgentQuestionRequest.self)
            _ = try await store.askQuestion(
                request,
                providerCallID: toolCall.providerCallID,
                taskID: context.task.id,
                jobID: context.job.id,
                attemptID: context.attempt.id
            )
            return .waiting

        case .finalResult:
            let request: AgentFinalResultRequest = try decode(toolCall, as: AgentFinalResultRequest.self)
            guard !request.spokenSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentRuntimeError.invalidToolCall
            }
            do {
                _ = try await store.finalize(
                    request,
                    taskID: context.task.id,
                    jobID: context.job.id,
                    attemptID: context.attempt.id
                )
                return .finished
            } catch let error as AgentRuntimeError {
                guard error == .finalResultSupersededBySteering else { throw error }
                return .response(
                    AgentToolResponse(
                        providerCallID: toolCall.providerCallID,
                        output: "{\"accepted\":false,\"reason\":\"New user steering arrived before finalization. Revise the result.\"}"
                    )
                )
            }
        }
    }

    private func decode<Payload: Decodable>(_ toolCall: AgentToolCall, as type: Payload.Type) throws -> Payload {
        do {
            return try toolCall.decode(type)
        } catch {
            throw AgentRuntimeError.invalidToolCall
        }
    }

    private static func appendUnique(
        _ item: AgentContinuationItem,
        to items: inout [AgentContinuationItem]
    ) {
        guard !items.contains(item) else { return }
        items.append(item)
    }

    private static func unresolvedToolCall(
        continuationItems: [AgentContinuationItem],
        toolOutputs: [AgentToolResponse]
    ) -> AgentToolCall? {
        let completedCallIDs = Set(toolOutputs.map(\.providerCallID))
        for continuationItem in continuationItems.reversed() {
            guard let functionCall = continuationItem.functionCall,
                  !completedCallIDs.contains(functionCall.callID) else {
                continue
            }
            return AgentToolCall(
                providerCallID: functionCall.callID,
                name: functionCall.name,
                arguments: functionCall.arguments
            )
        }
        return nil
    }

    private static func appendUniqueSteering(
        _ newInstructions: [AgentSteeringInstruction],
        to instructions: inout [AgentSteeringInstruction]
    ) {
        let existingIDs = Set(instructions.map(\.id))
        instructions.append(contentsOf: newInstructions.filter { !existingIDs.contains($0.id) })
    }

    private static func isTransientResponseFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .resourceUnavailable,
                 .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        if let apiError = error as? AgentAPIClientError,
           case .unsuccessfulResponse(let statusCode) = apiError {
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
        }
        guard let runtimeError = error as? AgentRuntimeError else { return false }
        return runtimeError == .remoteResponseUnavailable
    }

    private static func makeInput(
        context: AgentExecutionContext,
        steeringInstructions: [AgentSteeringInstruction],
        runtimeGuidance: [String]
    ) -> String {
        var sections = [
            "Task: \(context.task.instruction)",
            "Current job: \(context.job.instruction)",
            "Task id: \(context.task.id.uuidString)",
            "Job id: \(context.job.id.uuidString)"
        ]

        if let conversationContext = context.task.source.detail,
           !conversationContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Recent Macky conversation:\n\(conversationContext)")
        }

        if !context.task.skillSnapshots.isEmpty {
            let skills = context.task.skillSnapshots.map { skill in
                "Skill \(skill.displayName) [\(skill.id)]:\n\(skill.instructions)"
            }.joined(separator: "\n\n")
            sections.append("Explicitly attached Skills:\n\(skills)")
        }

        if !context.task.attachments.isEmpty {
            let attachments = context.task.attachments.map { attachment in
                "- id=\(attachment.id.uuidString), name=\(attachment.originalFilename), media_type=\(attachment.mediaType ?? "unknown"), bytes=\(attachment.byteCount)"
            }.joined(separator: "\n")
            sections.append("Explicit task attachments (read only with read_attachment):\n\(attachments)")
        }

        let questionHistory = context.questions.compactMap { question -> String? in
            guard let answer = question.answer else { return nil }
            return "Q: \(question.prompt)\nA: \(answer)"
        }
        if !questionHistory.isEmpty {
            sections.append("User answers:\n\(questionHistory.joined(separator: "\n\n"))")
        }

        if !steeringInstructions.isEmpty {
            sections.append(
                "New user steering to apply at this safe boundary:\n"
                    + steeringInstructions.map { "- \($0.text)" }.joined(separator: "\n")
            )
        }

        if !runtimeGuidance.isEmpty {
            sections.append(
                "Runtime guidance:\n" + runtimeGuidance.map { "- \($0)" }.joined(separator: "\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }
}

private enum AgentToolDisposition {
    case response(AgentToolResponse)
    case waiting
    case finished
}
