//
//  AgentLocalStore.swift
//  leanring-buddy
//

import Foundation

/// Serializes General Agent mutations, persistence, and observers. Event records only
/// enter this store through `appendEvent`, which always allocates a larger sequence.
actor AgentLocalStore {
    private let persistence: AgentStatePersisting
    private let now: @Sendable () -> Date
    private var state = AgentPersistentState.empty
    private var continuations: [UUID: AsyncStream<AgentStoreSnapshot>.Continuation] = [:]

    init(
        persistence: AgentStatePersisting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.now = now
    }

    func load() async throws -> AgentStoreSnapshot {
        state = try await persistence.load()
        publish()
        return snapshot()
    }

    func snapshot() -> AgentStoreSnapshot {
        AgentStoreSnapshot(state: state)
    }

    func updates() -> AsyncStream<AgentStoreSnapshot> {
        let continuationID = UUID()
        let currentSnapshot = snapshot()
        return AsyncStream { continuation in
            continuation.yield(currentSnapshot)
            Task {
                await self.addContinuation(continuation, id: continuationID)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeContinuation(id: continuationID)
                }
            }
        }
    }

    func create(task: AgentTask, jobs: [AgentJob]) async throws {
        guard !jobs.isEmpty,
              state.tasks.allSatisfy({ $0.id != task.id }),
              jobs.allSatisfy({ $0.taskID == task.id }),
              Set(jobs.map(\.id)).count == jobs.count else {
            throw AgentStoreError.invalidTaskCreation
        }
        let jobIDs = Set(jobs.map(\.id))
        guard task.parentGroups.allSatisfy({ group in
            group.taskID == task.id && Set(group.jobIDs).isSubset(of: jobIDs)
        }) else {
            throw AgentStoreError.invalidTaskCreation
        }

        state.tasks.append(task)
        state.jobs.append(contentsOf: jobs)
        appendEvent(taskID: task.id, kind: .taskCreated, message: task.instruction)
        for job in jobs {
            appendEvent(
                taskID: task.id,
                jobID: job.id,
                kind: .jobQueued,
                message: job.instruction
            )
        }
        try await persistAndPublish()
    }

    func task(id: UUID) throws -> AgentTask {
        guard let task = state.tasks.first(where: { $0.id == id }) else {
            throw AgentRuntimeError.missingTask(id)
        }
        return task
    }

    func job(id: UUID) throws -> AgentJob {
        guard let job = state.jobs.first(where: { $0.id == id }) else {
            throw AgentRuntimeError.missingJob(id)
        }
        return job
    }

    func jobs(for taskID: UUID) -> [AgentJob] {
        state.jobs.filter { $0.taskID == taskID }
    }

    func beginAttempt(for jobID: UUID) async throws -> AgentAttempt {
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        guard state.jobs[jobIndex].status == .queued else {
            throw AgentStoreError.jobIsNotQueued
        }

        let job = state.jobs[jobIndex]
        let attempt = AgentAttempt(
            taskID: job.taskID,
            jobID: job.id,
            ordinal: state.attempts.filter { $0.jobID == job.id }.count + 1,
            startedAt: now()
        )
        state.jobs[jobIndex].status = .running
        state.jobs[jobIndex].updatedAt = now()
        state.attempts.append(attempt)
        refreshTaskStatus(taskID: job.taskID)
        appendEvent(
            taskID: job.taskID,
            jobID: job.id,
            attemptID: attempt.id,
            kind: .attemptStarted,
            metadata: ["ordinal": String(attempt.ordinal)]
        )
        try await persistAndPublish()
        return attempt
    }

    func executionContext(
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID
    ) throws -> AgentExecutionContext {
        let task = try task(id: taskID)
        let job = try job(id: jobID)
        guard let attempt = state.attempts.first(where: { $0.id == attemptID }) else {
            throw AgentRuntimeError.missingAttempt(attemptID)
        }
        return AgentExecutionContext(
            task: task,
            job: job,
            attempt: attempt,
            priorEvents: state.events.filter { $0.taskID == taskID && $0.jobID == jobID },
            questions: state.questions.filter { $0.taskID == taskID && $0.jobID == jobID }
        )
    }

    func appendResponseText(
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID,
        text: String
    ) async throws {
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .responseTextReceived,
            message: text
        )
        try await persistAndPublish()
    }

    func recordToolRequest(
        _ toolCall: AgentToolCall,
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID
    ) async throws {
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .toolRequested,
            metadata: [
                "tool": toolCall.name.rawValue,
                "local_call_id": toolCall.id.uuidString,
                "provider_call_id": toolCall.providerCallID
            ]
        )
        try await persistAndPublish()
    }

    func checkpoint(
        jobID: UUID,
        continuationItems: [AgentContinuationItem],
        toolOutputs: [AgentToolResponse]
    ) async throws {
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        state.jobs[jobIndex].continuationItems = continuationItems
        state.jobs[jobIndex].toolOutputs = toolOutputs
        state.jobs[jobIndex].updatedAt = now()
        try await persistAndPublish()
    }

    func recordAttachmentChunk(
        _ chunk: AgentAttachmentChunk,
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID
    ) async throws {
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .attachmentChunkProvided,
            metadata: [
                "attachment_id": chunk.attachmentID.uuidString,
                "offset": String(chunk.offset),
                "byte_count": String(chunk.content.count)
            ]
        )
        try await persistAndPublish()
    }

    func createArtifact(
        _ request: AgentArtifactRequest,
        providerCallID: String,
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID
    ) async throws -> AgentArtifact {
        if let existingArtifact = state.artifacts.first(where: {
            $0.taskID == taskID && $0.jobID == jobID && $0.providerCallID == providerCallID
        }) {
            return existingArtifact
        }
        let artifact = AgentArtifact(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            providerCallID: providerCallID,
            name: request.name,
            mediaType: request.mediaType,
            encoding: request.encoding,
            content: request.content,
            createdAt: now()
        )
        state.artifacts.append(artifact)
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .artifactCreated,
            metadata: [
                "artifact_id": artifact.id.uuidString,
                "name": artifact.name,
                "provider_call_id": providerCallID
            ]
        )
        try await persistAndPublish()
        return artifact
    }

    func askQuestion(
        _ request: AgentQuestionRequest,
        providerCallID: String,
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID
    ) async throws -> AgentQuestion {
        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw AgentRuntimeError.invalidQuestion }
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }),
              let attemptIndex = state.attempts.firstIndex(where: { $0.id == attemptID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }

        let question = AgentQuestion(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            providerCallID: providerCallID,
            prompt: trimmedPrompt,
            options: request.options,
            createdAt: now()
        )
        state.questions.append(question)
        state.jobs[jobIndex].status = .waiting
        state.jobs[jobIndex].updatedAt = now()
        state.attempts[attemptIndex].status = .waiting
        state.attempts[attemptIndex].endedAt = now()
        refreshTaskStatus(taskID: taskID)
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .questionAsked,
            message: question.prompt,
            metadata: ["question_id": question.id.uuidString]
        )
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .waiting,
            metadata: ["question_id": question.id.uuidString]
        )
        try await persistAndPublish()
        return question
    }

    func answerQuestion(id: UUID, answer: String) async throws -> UUID {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty,
              let questionIndex = state.questions.firstIndex(where: { $0.id == id }) else {
            throw AgentRuntimeError.invalidQuestion
        }
        guard state.questions[questionIndex].status == .open,
              !state.questions[questionIndex].isExpired(at: now()),
              let providerCallID = state.questions[questionIndex].providerCallID,
              let jobIndex = state.jobs.firstIndex(where: { $0.id == state.questions[questionIndex].jobID }) else {
            throw AgentRuntimeError.invalidQuestion
        }

        state.questions[questionIndex].status = .answered
        state.questions[questionIndex].answer = trimmedAnswer
        state.questions[questionIndex].answeredAt = now()
        let answerOutput = try AgentToolResponse(
            providerCallID: providerCallID,
            payload: ["answer": trimmedAnswer]
        )
        var toolOutputs = state.jobs[jobIndex].toolOutputs ?? []
        toolOutputs.removeAll { $0.providerCallID == providerCallID }
        toolOutputs.append(answerOutput)
        state.jobs[jobIndex].toolOutputs = toolOutputs
        state.jobs[jobIndex].status = .queued
        state.jobs[jobIndex].updatedAt = now()
        refreshTaskStatus(taskID: state.questions[questionIndex].taskID)
        appendEvent(
            taskID: state.questions[questionIndex].taskID,
            jobID: state.questions[questionIndex].jobID,
            attemptID: state.questions[questionIndex].attemptID,
            kind: .questionAnswered,
            metadata: ["question_id": id.uuidString]
        )
        try await persistAndPublish()
        return state.questions[questionIndex].jobID
    }

    func queueSteering(taskID: UUID, text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw AgentRuntimeError.invalidSteering }
        let candidateStatuses: [AgentJobStatus] = [.running, .queued, .waiting]
        let jobIndices = state.jobs.indices.filter {
            state.jobs[$0].taskID == taskID && candidateStatuses.contains(state.jobs[$0].status)
        }
        guard !jobIndices.isEmpty else {
            throw AgentRuntimeError.missingTask(taskID)
        }
        let requestedAt = now()
        for jobIndex in jobIndices {
            let steering = AgentSteeringInstruction(text: trimmedText, requestedAt: requestedAt)
            state.jobs[jobIndex].pendingSteering.append(steering)
            state.jobs[jobIndex].updatedAt = requestedAt
            appendEvent(
                taskID: taskID,
                jobID: state.jobs[jobIndex].id,
                kind: .steeringQueued,
                message: trimmedText,
                metadata: ["steering_id": steering.id.uuidString]
            )
        }
        refreshTaskStatus(taskID: taskID)
        try await persistAndPublish()
    }

    func recordCancellationRequested(jobID: UUID) async throws {
        guard let job = state.jobs.first(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        appendEvent(
            taskID: job.taskID,
            jobID: job.id,
            kind: .cancellationRequested,
            message: "Cancellation will apply at the next safe step boundary"
        )
        try await persistAndPublish()
    }

    func pendingSteering(for jobID: UUID) throws -> [AgentSteeringInstruction] {
        guard let job = state.jobs.first(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        return job.pendingSteering
    }

    func markSteeringApplied(jobID: UUID, instructionIDs: Set<UUID>) async throws {
        guard !instructionIDs.isEmpty else { return }
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        let appliedInstructions = state.jobs[jobIndex].pendingSteering.filter {
            instructionIDs.contains($0.id)
        }
        guard !appliedInstructions.isEmpty else { return }
        state.jobs[jobIndex].pendingSteering.removeAll { instructionIDs.contains($0.id) }
        state.jobs[jobIndex].updatedAt = now()
        for instruction in appliedInstructions {
            appendEvent(
                taskID: state.jobs[jobIndex].taskID,
                jobID: jobID,
                kind: .steeringApplied,
                message: instruction.text,
                metadata: ["steering_id": instruction.id.uuidString]
            )
        }
        try await persistAndPublish()
    }

    func finalize(
        _ request: AgentFinalResultRequest,
        taskID: UUID,
        jobID: UUID,
        attemptID: UUID
    ) async throws -> AgentResult {
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }),
              let attemptIndex = state.attempts.firstIndex(where: { $0.id == attemptID }),
              let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        guard state.jobs[jobIndex].pendingSteering.isEmpty else {
            throw AgentRuntimeError.finalResultSupersededBySteering
        }
        let result = AgentResult(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            status: .completed,
            summary: request.summary,
            markdown: request.markdown,
            sources: request.sources,
            artifactIDs: request.artifactIDs,
            limitations: request.limitations,
            suggestedActions: request.suggestedActions,
            partial: request.partial,
            completedAt: now()
        )
        state.results.append(result)
        state.tasks[taskIndex].resultIDs.append(result.id)
        state.jobs[jobIndex].resultID = result.id
        state.jobs[jobIndex].status = .completed
        state.jobs[jobIndex].updatedAt = now()
        state.attempts[attemptIndex].status = .completed
        state.attempts[attemptIndex].endedAt = now()
        refreshTaskStatus(taskID: taskID)
        appendEvent(
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .resultFinalized,
            message: result.summary,
            metadata: ["result_id": result.id.uuidString]
        )
        appendEvent(taskID: taskID, jobID: jobID, attemptID: attemptID, kind: .completed)
        try await persistAndPublish()
        return result
    }

    func fail(jobID: UUID, attemptID: UUID?, detail: String) async throws {
        try await finishWithoutFinalResult(
            jobID: jobID,
            attemptID: attemptID,
            resultStatus: .failed,
            jobStatus: .failed,
            attemptStatus: .failed,
            eventKind: .failed,
            detail: detail
        )
    }

    func cancel(jobID: UUID, attemptID: UUID? = nil) async throws {
        try await finishWithoutFinalResult(
            jobID: jobID,
            attemptID: attemptID,
            resultStatus: .cancelled,
            jobStatus: .cancelled,
            attemptStatus: .cancelled,
            eventKind: .cancelled,
            detail: "Cancelled"
        )
    }

    func interrupt(jobID: UUID, attemptID: UUID? = nil, detail: String = "Interrupted") async throws {
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        if [.completed, .cancelled, .failed, .interrupted].contains(state.jobs[jobIndex].status) {
            return
        }
        state.jobs[jobIndex].status = .interrupted
        state.jobs[jobIndex].updatedAt = now()
        if let attemptID,
           let attemptIndex = state.attempts.firstIndex(where: { $0.id == attemptID }) {
            state.attempts[attemptIndex].status = .interrupted
            state.attempts[attemptIndex].endedAt = now()
        }
        refreshTaskStatus(taskID: state.jobs[jobIndex].taskID)
        appendEvent(
            taskID: state.jobs[jobIndex].taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .interrupted,
            message: detail
        )
        try await persistAndPublish()
    }

    /// Stops the current attempt but keeps its job queued so a process relaunch or
    /// system wake can resume it. This is used only for app/system lifecycle pauses,
    /// never for a user cancellation.
    func queueAfterLifecycleInterruption(
        jobID: UUID,
        attemptID: UUID?,
        detail: String
    ) async throws {
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        guard state.jobs[jobIndex].status != .completed,
              state.jobs[jobIndex].status != .cancelled,
              state.jobs[jobIndex].status != .failed else { return }

        state.jobs[jobIndex].status = .queued
        state.jobs[jobIndex].updatedAt = now()
        if let attemptID,
           let attemptIndex = state.attempts.firstIndex(where: { $0.id == attemptID }) {
            state.attempts[attemptIndex].status = .interrupted
            state.attempts[attemptIndex].endedAt = now()
        }
        refreshTaskStatus(taskID: state.jobs[jobIndex].taskID)
        appendEvent(
            taskID: state.jobs[jobIndex].taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: .interrupted,
            message: detail
        )
        appendEvent(taskID: state.jobs[jobIndex].taskID, jobID: jobID, kind: .jobQueued)
        try await persistAndPublish()
    }

    func restart(taskID: UUID) async throws -> [UUID] {
        guard state.tasks.contains(where: { $0.id == taskID }) else {
            throw AgentRuntimeError.missingTask(taskID)
        }
        let taskJobs = state.jobs.filter { $0.taskID == taskID }
        let shouldRestartAll = taskJobs.allSatisfy { $0.status == .completed }
        var restartedJobIDs: [UUID] = []
        for jobIndex in state.jobs.indices where state.jobs[jobIndex].taskID == taskID {
            let currentStatus = state.jobs[jobIndex].status
            guard shouldRestartAll || currentStatus == .interrupted || currentStatus == .failed || currentStatus == .cancelled else {
                continue
            }
            state.jobs[jobIndex].status = .queued
            state.jobs[jobIndex].resultID = nil
            state.jobs[jobIndex].continuationItems = nil
            state.jobs[jobIndex].toolOutputs = nil
            state.jobs[jobIndex].updatedAt = now()
            restartedJobIDs.append(state.jobs[jobIndex].id)
            appendEvent(taskID: taskID, jobID: state.jobs[jobIndex].id, kind: .restarted)
            appendEvent(taskID: taskID, jobID: state.jobs[jobIndex].id, kind: .jobQueued)
        }
        refreshTaskStatus(taskID: taskID)
        try await persistAndPublish()
        return restartedJobIDs
    }

    /// Restores work that was queued or running when Macky last exited. Running
    /// attempts are closed as interrupted, then their jobs are queued once for the
    /// new process. Waiting jobs stay waiting for the user's answer.
    func preparePersistedWorkForRelaunch() async throws -> [UUID] {
        var didChange = false
        var jobIDsToRestart: [UUID] = []
        for jobIndex in state.jobs.indices {
            switch state.jobs[jobIndex].status {
            case .queued, .running:
                let job = state.jobs[jobIndex]
                if state.jobs[jobIndex].status == .running,
                   let attemptIndex = state.attempts.lastIndex(where: {
                       $0.jobID == job.id && $0.status == .running
                   }) {
                    state.attempts[attemptIndex].status = .interrupted
                    state.attempts[attemptIndex].endedAt = now()
                    appendEvent(
                        taskID: job.taskID,
                        jobID: job.id,
                        attemptID: state.attempts[attemptIndex].id,
                        kind: .interrupted,
                        message: "Macky closed before this attempt finished"
                    )
                }
                state.jobs[jobIndex].status = .queued
                state.jobs[jobIndex].updatedAt = now()
                appendEvent(
                    taskID: job.taskID,
                    jobID: job.id,
                    kind: .restarted,
                    message: "Restarted when Macky reopened"
                )
                appendEvent(taskID: job.taskID, jobID: job.id, kind: .jobQueued)
                jobIDsToRestart.append(job.id)
                didChange = true
            case .waiting, .interrupted, .completed, .cancelled, .failed:
                break
            }
        }
        guard didChange else { return [] }
        for task in state.tasks {
            didChange = refreshTaskStatus(taskID: task.id) || didChange
        }
        try await persistAndPublish()
        return jobIDsToRestart
    }

    /// Applies 24-hour question expiry and 30-day terminal-history retention. The
    /// returned attachments are removed by the coordinator after their task records
    /// have been successfully persisted out of the local store.
    func enforceRetention(at date: Date? = nil) async throws -> [AgentAttachment] {
        let retentionDate = date ?? now()
        var didChange = false
        for questionIndex in state.questions.indices where state.questions[questionIndex].status == .open {
            guard state.questions[questionIndex].isExpired(at: retentionDate) else { continue }
            let question = state.questions[questionIndex]
            state.questions[questionIndex].status = .expired
            if let jobIndex = state.jobs.firstIndex(where: { $0.id == question.jobID }) {
                state.jobs[jobIndex].status = .interrupted
                state.jobs[jobIndex].updatedAt = retentionDate
            }
            if let attemptIndex = state.attempts.firstIndex(where: { $0.id == question.attemptID }) {
                state.attempts[attemptIndex].status = .interrupted
                state.attempts[attemptIndex].endedAt = retentionDate
            }
            appendEvent(
                taskID: question.taskID,
                jobID: question.jobID,
                attemptID: question.attemptID,
                kind: .questionExpired,
                metadata: ["question_id": question.id.uuidString]
            )
            appendEvent(
                taskID: question.taskID,
                jobID: question.jobID,
                attemptID: question.attemptID,
                kind: .interrupted,
                message: "Question expired"
            )
            didChange = true
        }

        for task in state.tasks {
            didChange = refreshTaskStatus(taskID: task.id) || didChange
        }

        let historyCutoff = retentionDate.addingTimeInterval(-AgentRetentionPolicy.historyLifetime)
        let expiredTaskIDs = Set(state.tasks.compactMap { task -> UUID? in
            guard task.updatedAt < historyCutoff, Self.isTerminal(task.status) else { return nil }
            return task.id
        })
        let expiredAttachments = state.tasks
            .filter { expiredTaskIDs.contains($0.id) }
            .flatMap(\.attachments)
        if !expiredTaskIDs.isEmpty {
            state.tasks.removeAll { expiredTaskIDs.contains($0.id) }
            state.jobs.removeAll { expiredTaskIDs.contains($0.taskID) }
            state.attempts.removeAll { expiredTaskIDs.contains($0.taskID) }
            state.events.removeAll { expiredTaskIDs.contains($0.taskID) }
            state.results.removeAll { expiredTaskIDs.contains($0.taskID) }
            state.artifacts.removeAll { expiredTaskIDs.contains($0.taskID) }
            state.questions.removeAll { expiredTaskIDs.contains($0.taskID) }
            didChange = true
        }

        if didChange {
            try await persistAndPublish()
        }
        return expiredAttachments
    }

    func deleteTask(id taskID: UUID) async throws -> [AgentAttachment] {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else {
            throw AgentRuntimeError.missingTask(taskID)
        }
        state.tasks.removeAll { $0.id == taskID }
        state.jobs.removeAll { $0.taskID == taskID }
        state.attempts.removeAll { $0.taskID == taskID }
        state.events.removeAll { $0.taskID == taskID }
        state.results.removeAll { $0.taskID == taskID }
        state.artifacts.removeAll { $0.taskID == taskID }
        state.questions.removeAll { $0.taskID == taskID }
        try await persistAndPublish()
        return task.attachments
    }

    private func finishWithoutFinalResult(
        jobID: UUID,
        attemptID: UUID?,
        resultStatus: AgentResultStatus,
        jobStatus: AgentJobStatus,
        attemptStatus: AgentAttemptStatus,
        eventKind: AgentEventKind,
        detail: String
    ) async throws {
        guard let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }),
              let taskIndex = state.tasks.firstIndex(where: { $0.id == state.jobs[jobIndex].taskID }) else {
            throw AgentRuntimeError.missingJob(jobID)
        }
        if [.completed, .cancelled, .failed, .interrupted].contains(state.jobs[jobIndex].status) {
            return
        }
        let resolvedAttemptID = attemptID ?? state.attempts.last(where: { $0.jobID == jobID })?.id
        let result = AgentResult(
            taskID: state.jobs[jobIndex].taskID,
            jobID: jobID,
            attemptID: resolvedAttemptID,
            status: resultStatus,
            summary: detail,
            completedAt: now(),
            errorDetail: resultStatus == .failed ? detail : nil
        )
        state.results.append(result)
        state.tasks[taskIndex].resultIDs.append(result.id)
        state.jobs[jobIndex].resultID = result.id
        state.jobs[jobIndex].status = jobStatus
        state.jobs[jobIndex].updatedAt = now()
        if let resolvedAttemptID,
           let attemptIndex = state.attempts.firstIndex(where: { $0.id == resolvedAttemptID }) {
            state.attempts[attemptIndex].status = attemptStatus
            state.attempts[attemptIndex].endedAt = now()
        }
        refreshTaskStatus(taskID: state.jobs[jobIndex].taskID)
        appendEvent(
            taskID: state.jobs[jobIndex].taskID,
            jobID: jobID,
            attemptID: resolvedAttemptID,
            kind: eventKind,
            message: detail,
            metadata: ["result_id": result.id.uuidString]
        )
        try await persistAndPublish()
    }

    @discardableResult
    private func refreshTaskStatus(taskID: UUID) -> Bool {
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) else { return false }
        let taskJobs = state.jobs.filter { $0.taskID == taskID }
        let newStatus: AgentTaskStatus
        if taskJobs.allSatisfy({ $0.status == .completed }) {
            newStatus = .completed
        } else if taskJobs.contains(where: { $0.status == .running }) {
            newStatus = .running
        } else if taskJobs.contains(where: { $0.status == .waiting }) {
            newStatus = .waiting
        } else if taskJobs.contains(where: { $0.status == .queued }) {
            newStatus = .queued
        } else if taskJobs.contains(where: { $0.status == .interrupted }) {
            newStatus = .interrupted
        } else if taskJobs.contains(where: { $0.status == .failed }) {
            newStatus = .failed
        } else {
            newStatus = .cancelled
        }
        if state.tasks[taskIndex].status != newStatus {
            state.tasks[taskIndex].status = newStatus
            state.tasks[taskIndex].updatedAt = now()
            return true
        }
        return false
    }

    private func appendEvent(
        taskID: UUID,
        jobID: UUID? = nil,
        attemptID: UUID? = nil,
        kind: AgentEventKind,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let eventDate = now()
        let event = AgentEvent(
            sequence: state.nextEventSequence,
            taskID: taskID,
            jobID: jobID,
            attemptID: attemptID,
            kind: kind,
            message: message,
            metadata: metadata,
            createdAt: eventDate
        )
        state.nextEventSequence += 1
        state.events.append(event)
        if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[taskIndex].updatedAt = eventDate
        }
    }

    private func persistAndPublish() async throws {
        try await persistence.save(state)
        publish()
    }

    private func publish() {
        let currentSnapshot = snapshot()
        for continuation in continuations.values {
            continuation.yield(currentSnapshot)
        }
    }

    private func addContinuation(
        _ continuation: AsyncStream<AgentStoreSnapshot>.Continuation,
        id: UUID
    ) {
        continuations[id] = continuation
        continuation.yield(snapshot())
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func isTerminal(_ status: AgentTaskStatus) -> Bool {
        switch status {
        case .completed, .cancelled, .failed, .interrupted:
            return true
        case .queued, .running, .waiting:
            return false
        }
    }
}

struct AgentExecutionContext: Sendable {
    let task: AgentTask
    let job: AgentJob
    let attempt: AgentAttempt
    let priorEvents: [AgentEvent]
    let questions: [AgentQuestion]
}

enum AgentStoreError: LocalizedError, Equatable {
    case invalidTaskCreation
    case jobIsNotQueued

    var errorDescription: String? {
        switch self {
        case .invalidTaskCreation:
            return "The General Agent task and jobs are inconsistent."
        case .jobIsNotQueued:
            return "The General Agent job is not ready to start."
        }
    }
}
