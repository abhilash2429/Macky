//
//  AgentCoordinator.swift
//  leanring-buddy
//

import Combine
import Foundation

enum AgentCoordinatorAvailability: Equatable {
    case loading
    case available
    case unavailable(String)
}

enum AgentNoticeKind: String, Equatable, Sendable {
    case completed
    case needsInput
    case failed
}

struct AgentNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: UUID
    let kind: AgentNoticeKind
    let title: String
    let detail: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        kind: AgentNoticeKind,
        title: String,
        detail: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
    }
}

/// Main-actor façade for a future UI or voice entry point. It deliberately has no
/// dependency on CompanionManager, RealtimeClient, or any panel view in this slice.
@MainActor
final class AgentCoordinator: ObservableObject {
    @Published private(set) var availability: AgentCoordinatorAvailability = .loading
    @Published private(set) var tasks: [AgentTask] = []
    @Published private(set) var recentTasks: [AgentTask] = []
    @Published private(set) var historyTasks: [AgentTask] = []
    @Published private(set) var jobs: [AgentJob] = []
    @Published private(set) var attempts: [AgentAttempt] = []
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var results: [AgentResult] = []
    @Published private(set) var artifacts: [AgentArtifact] = []
    @Published private(set) var questions: [AgentQuestion] = []
    @Published private(set) var notices: [AgentNotice] = []
    @Published var selectedTaskID: UUID?
    @Published private(set) var shouldPresentAgentsPage = false

    let generalAgent = AgentRegistry.general

    private let store: AgentLocalStore
    private let runtime: AgentRuntime
    private let attachmentStore: AgentAttachmentAccessing
    private let now: @Sendable () -> Date
    private var observationTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var hasStarted = false
    private var sleepPausedJobIDs: [UUID] = []

    init(
        persistence: AgentStatePersisting = AgentEncryptedPersistence(),
        apiClient: AgentAPIServing = AgentAPIClient(),
        attachmentStore: AgentAttachmentAccessing = AgentAttachmentStore(),
        javaScriptExecutor: AgentJavaScriptExecuting? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let store = AgentLocalStore(persistence: persistence, now: now)
        self.store = store
        self.attachmentStore = attachmentStore
        self.runtime = AgentRuntime(
            store: store,
            apiClient: apiClient,
            attachmentStore: attachmentStore,
            javaScriptExecutor: javaScriptExecutor ?? AgentJavaScriptExecutorClient.shared
        )
        self.now = now
    }

    deinit {
        observationTask?.cancel()
        retentionTask?.cancel()
    }

    /// Loads encrypted local state, applies retention, and resumes work that was queued
    /// or running when Macky last exited. Recovery happens once per app process.
    func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true
        availability = .loading
        observationTask?.cancel()
        do {
            apply(try await store.load())
            let updateStream = await store.updates()
            observationTask = Task { @MainActor [weak self] in
                for await snapshot in updateStream {
                    guard !Task.isCancelled else { return }
                    self?.apply(snapshot)
                }
            }
            retentionTask?.cancel()
            retentionTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, !Task.isCancelled else { return }
                    self.refreshTimeDerivedCollections()
                    if let expiredAttachments = try? await self.store.enforceRetention(at: self.now()) {
                        await self.attachmentStore.delete(expiredAttachments)
                    }
                }
            }
            let expiredAttachments = try await store.enforceRetention(at: now())
            await attachmentStore.delete(expiredAttachments)
            let recoveredJobIDs = try await store.preparePersistedWorkForRelaunch()
            await runtime.enqueue(jobIDs: recoveredJobIDs)
            availability = .available
        } catch {
            hasStarted = false
            observationTask?.cancel()
            observationTask = nil
            retentionTask?.cancel()
            retentionTask = nil
            availability = .unavailable(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        observationTask?.cancel()
        observationTask = nil
        retentionTask?.cancel()
        retentionTask = nil
        await runtime.stop()
    }

    func pauseForSystemSleep() async {
        sleepPausedJobIDs = await runtime.pauseForSystemSleep()
    }

    func resumeAfterSystemWake() async {
        let jobIDs = sleepPausedJobIDs
        sleepPausedJobIDs = []
        await runtime.resumeAfterSystemWake(jobIDs: jobIDs)
    }

    func submit(
        instruction: String,
        source: AgentSource,
        attachmentURLs: [URL] = [],
        skillSnapshots: [AgentSkillSnapshot] = [],
        childInstructions: [String] = []
    ) async throws -> AgentTask {
        guard availability == .available else {
            throw AgentCoordinatorError.temporarilyUnavailable
        }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else { throw AgentCoordinatorError.emptyInstruction }

        let normalizedChildInstructions = (childInstructions.isEmpty ? [trimmedInstruction] : childInstructions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalizedChildInstructions.allSatisfy({ !$0.isEmpty }) else {
            throw AgentCoordinatorError.emptyInstruction
        }
        guard normalizedChildInstructions.count <= AgentParentGroup.maximumJobCount else {
            throw AgentCoordinatorError.tooManyChildJobs
        }

        let taskID = UUID()
        let attachments = try await attachmentStore.copyAttachments(from: attachmentURLs, for: taskID)
        let jobIDs = normalizedChildInstructions.map { _ in UUID() }
        let parentGroup = normalizedChildInstructions.count > 1
            ? try AgentParentGroup(taskID: taskID, jobIDs: jobIDs)
            : nil
        let jobs = zip(jobIDs, normalizedChildInstructions).map { jobID, childInstruction in
            AgentJob(
                id: jobID,
                taskID: taskID,
                parentGroupID: parentGroup?.id,
                instruction: childInstruction,
                createdAt: now()
            )
        }
        let task = AgentTask(
            id: taskID,
            agentID: generalAgent.id,
            instruction: trimmedInstruction,
            source: source,
            skillSnapshots: skillSnapshots,
            attachments: attachments,
            parentGroups: parentGroup.map { [$0] } ?? [],
            createdAt: now()
        )

        do {
            try await store.create(task: task, jobs: jobs)
        } catch {
            await attachmentStore.delete(attachments)
            throw error
        }
        MackyAnalytics.agentLifecycle(outcome: "spawned", agentType: task.agentID)
        await runtime.enqueue(jobIDs: jobIDs)
        return task
    }

    func cancel(taskID: UUID) async throws {
        try await runtime.cancel(taskID: taskID)
    }

    func restart(taskID: UUID) async throws {
        try await runtime.restart(taskID: taskID)
    }

    /// Steering is saved immediately but applied only when the runtime reaches a
    /// safe response or tool boundary; it never interrupts a tool mid-dispatch.
    func steer(taskID: UUID, text: String) async throws {
        try await runtime.steer(taskID: taskID, text: text)
    }

    func answer(questionID: UUID, answer: String) async throws {
        try await runtime.answer(questionID: questionID, answer: answer)
    }

    func delete(taskID: UUID) async throws {
        guard let task = task(id: taskID) else {
            throw AgentRuntimeError.missingTask(taskID)
        }
        guard Self.isTerminal(task.status) else {
            throw AgentCoordinatorError.taskMustFinishBeforeDeletion
        }
        let attachments = try await store.deleteTask(id: taskID)
        await attachmentStore.delete(attachments)
        notices.removeAll { $0.taskID == taskID }
        if selectedTaskID == taskID {
            selectedTaskID = nil
        }
    }

    func openAgentsPage(taskID: UUID? = nil) {
        if let taskID, tasks.contains(where: { $0.id == taskID }) {
            selectedTaskID = taskID
        }
        shouldPresentAgentsPage = true
    }

    func consumeAgentsPagePresentation() {
        shouldPresentAgentsPage = false
    }

    func dismissNotice(id: UUID) {
        notices.removeAll { $0.id == id }
    }

    func task(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    func jobs(for taskID: UUID) -> [AgentJob] {
        jobs.filter { $0.taskID == taskID }
    }

    func events(for taskID: UUID) -> [AgentEvent] {
        events.filter { $0.taskID == taskID }.sorted { $0.sequence < $1.sequence }
    }

    func results(for taskID: UUID) -> [AgentResult] {
        results.filter { $0.taskID == taskID }.sorted { $0.completedAt < $1.completedAt }
    }

    func artifacts(for taskID: UUID) -> [AgentArtifact] {
        artifacts.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }

    func questions(for taskID: UUID) -> [AgentQuestion] {
        questions.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }

    private func apply(_ snapshot: AgentStoreSnapshot) {
        let priorStatuses = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
        tasks = snapshot.tasks.sorted { $0.updatedAt > $1.updatedAt }
        refreshTimeDerivedCollections()
        jobs = snapshot.jobs
        attempts = snapshot.attempts
        events = snapshot.events
        results = snapshot.results
        artifacts = snapshot.artifacts
        questions = snapshot.questions

        for task in tasks {
            guard let priorStatus = priorStatuses[task.id], priorStatus != task.status else { continue }
            if task.status != .waiting {
                notices.removeAll { $0.taskID == task.id && $0.kind == .needsInput }
            }
            if task.status != .failed {
                notices.removeAll { $0.taskID == task.id && $0.kind == .failed }
            }
            if task.status != .completed {
                notices.removeAll { $0.taskID == task.id && $0.kind == .completed }
            }
            switch task.status {
            case .completed:
                recordTerminalAnalytics(task: task, outcome: "completed")
                appendNotice(
                    taskID: task.id,
                    kind: .completed,
                    title: "Agent finished",
                    detail: task.instruction
                )
            case .waiting:
                appendNotice(
                    taskID: task.id,
                    kind: .needsInput,
                    title: "Agent needs input",
                    detail: task.instruction
                )
            case .failed:
                recordTerminalAnalytics(task: task, outcome: "failed")
                appendNotice(
                    taskID: task.id,
                    kind: .failed,
                    title: "Agent stopped",
                    detail: task.instruction
                )
            case .cancelled:
                recordTerminalAnalytics(task: task, outcome: "cancelled")
            case .interrupted:
                recordTerminalAnalytics(task: task, outcome: "interrupted")
            case .queued, .running:
                break
            }
        }
    }

    private func refreshTimeDerivedCollections() {
        recentTasks = AgentRetentionPolicy.recentTasks(in: tasks, at: now())
        historyTasks = AgentRetentionPolicy.historyTasks(in: tasks, at: now())
    }

    private func appendNotice(
        taskID: UUID,
        kind: AgentNoticeKind,
        title: String,
        detail: String
    ) {
        guard !notices.contains(where: { $0.taskID == taskID && $0.kind == kind }) else { return }
        notices.append(
            AgentNotice(
                taskID: taskID,
                kind: kind,
                title: title,
                detail: detail,
                createdAt: now()
            )
        )
    }

    private func recordTerminalAnalytics(task: AgentTask, outcome: String) {
        let toolCount = events.lazy.filter {
            $0.taskID == task.id && $0.kind == .toolRequested
        }.count
        MackyAnalytics.agentLifecycle(
            outcome: outcome,
            agentType: task.agentID,
            durationMilliseconds: max(0, Int(task.updatedAt.timeIntervalSince(task.createdAt) * 1_000)),
            toolCount: toolCount
        )
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

enum AgentCoordinatorError: LocalizedError, Equatable {
    case emptyInstruction
    case tooManyChildJobs
    case temporarilyUnavailable
    case taskMustFinishBeforeDeletion

    var errorDescription: String? {
        switch self {
        case .emptyInstruction:
            return "A General Agent task needs an instruction."
        case .tooManyChildJobs:
            return "A General Agent parent group can contain at most \(AgentParentGroup.maximumJobCount) jobs."
        case .temporarilyUnavailable:
            return "Background agents are temporarily unavailable."
        case .taskMustFinishBeforeDeletion:
            return "Cancel or finish this background task before deleting it."
        }
    }
}
