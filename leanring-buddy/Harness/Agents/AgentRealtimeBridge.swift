//
//  AgentRealtimeBridge.swift
//  leanring-buddy
//

import Foundation

/// Registers the small background-agent control surface exposed to Realtime.
/// Agent execution remains asynchronous and never participates in Realtime's
/// voice/tool activity state after the spawn call itself returns.
@MainActor
final class AgentRealtimeBridge {
    private static let maximumConversationAge: TimeInterval = 30 * 60
    private static let maximumConversationTurns = 12

    private let coordinator: AgentCoordinator
    private let enabledSkillIDs: () -> Set<String>
    private let conversationHistory: () -> [Interaction]

    init(
        coordinator: AgentCoordinator,
        enabledSkillIDs: @escaping () -> Set<String>,
        conversationHistory: @escaping () -> [Interaction]
    ) {
        self.coordinator = coordinator
        self.enabledSkillIDs = enabledSkillIDs
        self.conversationHistory = conversationHistory
    }

    func registerTools(on realtimeClient: RealtimeClient) {
        realtimeClient.registerTool(
            name: "spawn_agents",
            description: "Start one background General Agent task, optionally split into up to three independent child jobs. Use only for genuinely long-running research, multi-document synthesis, artifact generation, local analysis, or explicitly requested background work. Skills must be selected by id; voice-spawned tasks receive no file attachments.",
            reportsActivity: false,
            schema: [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "instruction": ["type": "string", "minLength": 1, "maxLength": 20_000],
                    "child_instructions": [
                        "type": "array",
                        "items": ["type": "string", "minLength": 1, "maxLength": 20_000],
                        "maxItems": AgentParentGroup.maximumJobCount
                    ],
                    "skill_ids": [
                        "type": "array",
                        "items": ["type": "string", "minLength": 1],
                        "uniqueItems": true
                    ]
                ],
                "required": ["instruction"]
            ]
        ) { [weak self] arguments in
            guard let self else { return Self.errorJSON("Agent bridge unavailable.") }
            return await self.spawn(arguments: arguments)
        }

        realtimeClient.registerTool(
            name: "list_agent_tasks",
            description: "List local background-agent tasks and statuses. By default returns active and recent tasks; request history only when the user asks for older work.",
            reportsActivity: false,
            schema: [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "include_history": ["type": "boolean"]
                ]
            ]
        ) { [weak self] arguments in
            guard let self else { return Self.errorJSON("Agent bridge unavailable.") }
            let includeHistory = arguments["include_history"] as? Bool ?? false
            return Self.jsonString(self.taskList(includeHistory: includeHistory))
        }

        realtimeClient.registerTool(
            name: "get_agent_result",
            description: "Get the current status and locally stored result for one background-agent task id.",
            reportsActivity: false,
            schema: Self.taskIDSchema
        ) { [weak self] arguments in
            guard let self else { return Self.errorJSON("Agent bridge unavailable.") }
            return self.result(arguments: arguments)
        }

        realtimeClient.registerTool(
            name: "cancel_agent",
            description: "Cancel one local background-agent task. The task id must come from spawn_agents or list_agent_tasks.",
            reportsActivity: false,
            schema: Self.taskIDSchema
        ) { [weak self] arguments in
            guard let self else { return Self.errorJSON("Agent bridge unavailable.") }
            return await self.cancel(arguments: arguments)
        }

        realtimeClient.registerTool(
            name: "open_agents_page",
            description: "Open Macky's Agents page, optionally focused on one exact task thread.",
            reportsActivity: false,
            schema: [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "task_id": ["type": ["string", "null"]]
                ]
            ]
        ) { [weak self] arguments in
            guard let self else { return Self.errorJSON("Agent bridge unavailable.") }
            return self.open(arguments: arguments)
        }
    }

    private func spawn(arguments: [String: Any]) async -> String {
        guard let instruction = Self.nonEmptyString(arguments["instruction"]) else {
            return Self.errorJSON("A background task instruction is required.")
        }
        let childInstructions = (arguments["child_instructions"] as? [String] ?? [])
            .compactMap(Self.trimmedNonEmptyString)
        guard childInstructions.count <= AgentParentGroup.maximumJobCount else {
            return Self.errorJSON("At most three background jobs can be started together.")
        }

        do {
            let skillSnapshots = try selectedSkillSnapshots(arguments["skill_ids"] as? [String] ?? [])
            let task = try await coordinator.submit(
                instruction: instruction,
                source: AgentSource(kind: .voice, detail: conversationContext()),
                skillSnapshots: skillSnapshots,
                childInstructions: childInstructions
            )
            let jobCount = childInstructions.isEmpty ? 1 : childInstructions.count
            coordinator.openAgentsPage(taskID: task.id)
            return Self.jsonString([
                "status": "spawned",
                "task_id": task.id.uuidString,
                "job_count": jobCount
            ])
        } catch {
            return Self.errorJSON(error.localizedDescription)
        }
    }

    private func selectedSkillSnapshots(_ requestedIDs: [String]) throws -> [AgentSkillSnapshot] {
        let enabledIDs = enabledSkillIDs()
        var seenIDs = Set<String>()
        return try requestedIDs.compactMap { requestedID in
            let normalizedID = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, seenIDs.insert(normalizedID).inserted else { return nil }
            guard enabledIDs.contains(normalizedID),
                  let skill = SkillRegistry.identity(forID: normalizedID),
                  skill.compatibleAgentTypes.isEmpty
                    || skill.compatibleAgentTypes.contains(where: { $0.caseInsensitiveCompare("general") == .orderedSame })
            else {
                throw AgentRealtimeBridgeError.skillUnavailable(normalizedID)
            }
            return AgentSkillSnapshot(
                id: skill.id,
                displayName: skill.displayName,
                instructions: skill.instructions
            )
        }
    }

    private func taskList(includeHistory: Bool) -> [[String: Any]] {
        let sourceTasks: [AgentTask]
        if includeHistory {
            sourceTasks = coordinator.historyTasks
        } else {
            let activeTasks = coordinator.tasks.filter {
                [.queued, .running, .waiting].contains($0.status)
            }
            let activeTaskIDs = Set(activeTasks.map(\.id))
            sourceTasks = activeTasks + coordinator.recentTasks.filter {
                !activeTaskIDs.contains($0.id)
            }
        }
        return sourceTasks.map { task in
            [
                "task_id": task.id.uuidString,
                "instruction": task.instruction,
                "status": task.status.rawValue,
                "updated_at": ISO8601DateFormatter().string(from: task.updatedAt),
                "job_count": coordinator.jobs(for: task.id).count
            ]
        }
    }

    private func result(arguments: [String: Any]) -> String {
        guard let taskID = Self.taskID(arguments) else {
            return Self.errorJSON("A valid task_id is required.")
        }
        guard let task = coordinator.task(id: taskID) else {
            return Self.errorJSON("No local background task matches that id.")
        }
        let taskResults = coordinator.results(for: taskID)
        let resultValues: [[String: Any]] = taskResults.map { result in
            let job = coordinator.jobs(for: taskID).first { $0.id == result.jobID }
            return [
                "result_id": result.id.uuidString,
                "job_id": result.jobID.uuidString,
                "job_instruction": job?.instruction ?? "",
                "status": result.status.rawValue,
                "summary": result.summary,
                "markdown": result.markdown,
                "sources": result.sources.map { ["title": $0.title, "url": $0.url] },
                "artifact_ids": result.artifactIDs.map(\.uuidString),
                "limitations": result.limitations,
                "suggested_actions": result.suggestedActions,
                "partial": result.partial,
                "completed_at": ISO8601DateFormatter().string(from: result.completedAt),
                "error": result.errorDetail.map { $0 as Any } ?? NSNull()
            ]
        }
        return Self.jsonString([
            "task_id": task.id.uuidString,
            "status": task.status.rawValue,
            "results": resultValues
        ])
    }

    private func cancel(arguments: [String: Any]) async -> String {
        guard let taskID = Self.taskID(arguments) else {
            return Self.errorJSON("A valid task_id is required.")
        }
        do {
            try await coordinator.cancel(taskID: taskID)
            let status = coordinator.task(id: taskID)?.status == .cancelled
                ? "cancelled"
                : "cancellation_requested"
            return Self.jsonString(["status": status, "task_id": taskID.uuidString])
        } catch {
            return Self.errorJSON(error.localizedDescription)
        }
    }

    private func open(arguments: [String: Any]) -> String {
        let taskID: UUID?
        if arguments["task_id"] is NSNull || arguments["task_id"] == nil {
            taskID = nil
        } else {
            guard let parsedTaskID = Self.taskID(arguments) else {
                return Self.errorJSON("task_id must be a valid local task id.")
            }
            taskID = parsedTaskID
        }
        coordinator.openAgentsPage(taskID: taskID)
        return Self.jsonString([
            "status": "opened",
            "task_id": taskID.map { $0.uuidString as Any } ?? NSNull()
        ])
    }

    private func conversationContext(now: Date = Date()) -> String? {
        let cutoff = now.addingTimeInterval(-Self.maximumConversationAge)
        let interactions = conversationHistory()
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(Self.maximumConversationTurns)
        guard !interactions.isEmpty else { return nil }
        return interactions.map { interaction in
            "User: \(interaction.userPhrase)\nMacky: \(interaction.modelSummary)"
        }.joined(separator: "\n\n")
    }

    private static let taskIDSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "task_id": ["type": "string", "format": "uuid"]
        ],
        "required": ["task_id"]
    ]

    private static func taskID(_ arguments: [String: Any]) -> UUID? {
        guard let value = nonEmptyString(arguments["task_id"]) else { return nil }
        return UUID(uuidString: value)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return trimmedNonEmptyString(value)
    }

    private static func trimmedNonEmptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func errorJSON(_ detail: String) -> String {
        jsonString(["error": detail])
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Could not encode the local agent response.\"}"
        }
        return string
    }
}

private enum AgentRealtimeBridgeError: LocalizedError {
    case skillUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .skillUnavailable(let skillID):
            return "Skill \(skillID) is unavailable, disabled, or incompatible with the General Agent."
        }
    }
}
