//
//  AgentsPanelView.swift
//  leanring-buddy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentsPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var coordinator: AgentCoordinator

    @State private var isCreatingTask = false
    @State private var draftInstruction = ""
    @State private var draftChildInstructions: [String] = []
    @State private var draftAttachmentURLs: [URL] = []
    @State private var draftSkillIDs = Set<String>()
    @State private var composerText = ""
    @State private var isShowingFileImporter = false
    @State private var taskPendingDeletion: AgentTask?
    @State private var errorMessage: String?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._coordinator = ObservedObject(wrappedValue: companionManager.agentCoordinator)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let notice = coordinator.notices.first {
                noticeBanner(notice)
            }

            if isCreatingTask {
                newTaskView
            } else if let selectedTaskID = coordinator.selectedTaskID,
                      let selectedTask = coordinator.task(id: selectedTaskID) {
                taskThread(selectedTask)
            } else {
                overview
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .animation(.easeOut(duration: 0.18), value: isCreatingTask)
        .animation(.easeOut(duration: 0.18), value: coordinator.selectedTaskID)
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                appendDraftAttachments(urls)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Delete this agent task?",
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let task = taskPendingDeletion else { return }
                Task { await delete(task) }
            }
            Button("Cancel", role: .cancel) { taskPendingDeletion = nil }
        } message: {
            Text("Its local thread, results, artifacts, and copied attachments will be removed.")
        }
    }

    private var overview: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GENERAL AGENT")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(DS.Colors.textTertiary)
                        Text(availabilityText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer()
                    Button {
                        isCreatingTask = true
                        errorMessage = nil
                    } label: {
                        Label("New task", systemImage: "plus")
                    }
                    .dsOutlinedButtonStyle(isFullWidth: false)
                    .disabled(coordinator.availability != .available)
                }

                taskSection(title: "ACTIVE", tasks: activeTasks)
                taskSection(title: "RECENT · 4 HOURS", tasks: recentTerminalTasks)
                taskSection(title: "HISTORY · 30 DAYS", tasks: olderHistoryTasks)
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func taskSection(title: String, tasks: [AgentTask]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(DS.Colors.textTertiary)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(tasks) { task in
                            taskCard(task)
                        }
                    }
                    .padding(.bottom, 3)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func taskCard(_ task: AgentTask) -> some View {
        Button {
            coordinator.selectedTaskID = task.id
            errorMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: statusIcon(task.status))
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text(task.status.rawValue.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.7)
                }
                .foregroundStyle(statusColor(task.status))

                Text(task.instruction)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Text(relativeTime(task.updatedAt))
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .padding(10)
            .frame(width: 112, height: 112, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var newTaskView: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    isCreatingTask = false
                    resetDraft()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .dsIconButtonStyle(size: 24, tooltip: "Back", tooltipAlignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text("New background task")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Long-running work only · up to three agents run concurrently")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                Spacer()
            }

            TextEditor(text: $draftInstruction)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 66, maxHeight: 78)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.Colors.borderSubtle))
                .overlay(alignment: .topLeading) {
                    if draftInstruction.isEmpty {
                        Text("Describe the research, synthesis, artifact, or local analysis…")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                }

            if !draftChildInstructions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PARALLEL AGENTS")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(DS.Colors.textTertiary)

                    ForEach(draftChildInstructions.indices, id: \.self) { index in
                        HStack(spacing: 5) {
                            TextField(
                                "Agent \(index + 1) instruction",
                                text: Binding(
                                    get: { draftChildInstructions[index] },
                                    set: { draftChildInstructions[index] = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 9, design: .rounded))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.Colors.borderSubtle))

                            Button {
                                draftChildInstructions.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .dsIconButtonStyle(size: 22, tooltip: "Remove agent", tooltipAlignment: .trailing)
                        }
                    }
                }
            }

            if !availableSkills.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(availableSkills) { skill in
                            skillChip(skill)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if !draftAttachmentURLs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(draftAttachmentURLs, id: \.self) { url in
                            attachmentChip(url)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(DS.Colors.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    isShowingFileImporter = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .dsTertiaryButtonStyle()

                if draftChildInstructions.count < AgentParentGroup.maximumJobCount {
                    Button {
                        if draftChildInstructions.isEmpty {
                            draftChildInstructions = ["", ""]
                        } else {
                            draftChildInstructions.append("")
                        }
                    } label: {
                        Label("Parallel", systemImage: "square.stack.3d.up")
                    }
                    .dsTertiaryButtonStyle()
                }

                Spacer()

                Button("Start") {
                    Task { await submitDraft() }
                }
                .dsOutlinedButtonStyle(isFullWidth: false)
                .disabled(!canSubmitDraft)
            }
        }
        .padding(.horizontal, 4)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            ingestDraftDrop(providers)
            return true
        }
    }

    private func taskThread(_ task: AgentTask) -> some View {
        let threadBottomID = "agent-thread-bottom-\(task.id.uuidString)"
        return VStack(spacing: 7) {
            HStack(spacing: 7) {
                Button {
                    coordinator.selectedTaskID = nil
                    composerText = ""
                    errorMessage = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .dsIconButtonStyle(size: 24, tooltip: "All agents", tooltipAlignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.instruction)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(task.status.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(statusColor(task.status))
                }

                Spacer()
                threadActions(task)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        threadRow(icon: "text.quote", title: "Request", detail: task.instruction)

                        let taskJobs = coordinator.jobs(for: task.id)
                        if taskJobs.count > 1 {
                            jobGroupView(taskJobs)
                        }

                        ForEach(eventDisplays(for: task.id)) { event in
                            eventRow(event)
                        }

                        ForEach(coordinator.results(for: task.id)) { result in
                            resultView(result, task: task)
                        }

                        ForEach(coordinator.artifacts(for: task.id)) { artifact in
                            artifactRow(artifact, task: task)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(threadBottomID)
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.visible)
                .onChange(of: coordinator.events.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(threadBottomID, anchor: .bottom)
                    }
                }
                .onChange(of: coordinator.results.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(threadBottomID, anchor: .bottom)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(DS.Colors.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if canCompose(task.status) {
                composer(task)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func threadActions(_ task: AgentTask) -> some View {
        HStack(spacing: 4) {
            switch task.status {
            case .queued, .running, .waiting:
                Button("Cancel") { Task { await cancel(task) } }
                    .dsTextButtonStyle(fontSize: 9)
            case .interrupted, .failed, .cancelled:
                Button("Restart") { Task { await restart(task) } }
                    .dsTextButtonStyle(fontSize: 9)
                Button {
                    taskPendingDeletion = task
                } label: {
                    Image(systemName: "trash")
                }
                .dsIconButtonStyle(size: 22, isDestructiveOnHover: true, tooltip: "Delete", tooltipAlignment: .trailing)
            case .completed:
                Button("Restart") { Task { await restart(task) } }
                    .dsTextButtonStyle(fontSize: 9)
                Button {
                    taskPendingDeletion = task
                } label: {
                    Image(systemName: "trash")
                }
                .dsIconButtonStyle(size: 22, isDestructiveOnHover: true, tooltip: "Delete", tooltipAlignment: .trailing)
            }
        }
    }

    private func composer(_ task: AgentTask) -> some View {
        let openQuestion = coordinator.questions(for: task.id).last { $0.status == .open }
        return HStack(spacing: 6) {
            TextField(openQuestion == nil ? "Steer this agent…" : "Answer the agent…", text: $composerText)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .rounded))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(DS.Colors.surface2))
                .overlay(Capsule().stroke(DS.Colors.borderSubtle))
                .onSubmit { Task { await sendComposer(task, question: openQuestion) } }

            Button {
                Task { await sendComposer(task, question: openQuestion) }
            } label: {
                Image(systemName: "arrow.up")
            }
            .dsIconButtonStyle(size: 28, tooltip: openQuestion == nil ? "Steer" : "Answer", tooltipAlignment: .trailing)
            .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func eventRow(_ event: AgentEventDisplay) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch event.state {
                case .active:
                    ProgressView()
                        .controlSize(.mini)
                case .completed:
                    Image(systemName: "checkmark")
                        .foregroundStyle(DS.Colors.success)
                case .failed:
                    Image(systemName: "exclamationmark")
                        .foregroundStyle(DS.Colors.warningText)
                case .info:
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
            .frame(width: 13, height: 13)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.textSecondary)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(event.kind == .responseTextReceived ? 4 : 2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func eventDisplays(for taskID: UUID) -> [AgentEventDisplay] {
        var displays: [AgentEventDisplay] = []
        var pendingResponseID: UUID?
        var pendingResponseJobID: UUID?
        var pendingResponseText = ""
        let taskJobs = coordinator.jobs(for: taskID)
        let jobNumbers = Dictionary(uniqueKeysWithValues: taskJobs.enumerated().map { index, job in
            (job.id, index + 1)
        })

        func flushResponseText() {
            guard let responseID = pendingResponseID, !pendingResponseText.isEmpty else { return }
            let agentPrefix = jobPrefix(
                for: pendingResponseJobID,
                jobNumbers: jobNumbers,
                jobCount: taskJobs.count
            )
            displays.append(
                AgentEventDisplay(
                    id: responseID,
                    jobID: pendingResponseJobID,
                    kind: .responseTextReceived,
                    title: agentPrefix + "Working",
                    detail: cleanedProgressText(pendingResponseText),
                    state: .completed
                )
            )
            pendingResponseText = ""
            pendingResponseID = nil
            pendingResponseJobID = nil
        }

        for event in coordinator.events(for: taskID) {
            if event.kind == .responseTextReceived {
                if pendingResponseJobID != nil, pendingResponseJobID != event.jobID {
                    flushResponseText()
                }
                pendingResponseID = pendingResponseID ?? event.id
                pendingResponseJobID = event.jobID
                pendingResponseText += event.message ?? ""
                continue
            }
            flushResponseText()
            guard let display = eventDisplay(
                event,
                jobNumbers: jobNumbers,
                jobCount: taskJobs.count
            ) else { continue }
            displays.append(display)
        }
        flushResponseText()

        for job in taskJobs where job.status == .running {
            guard let lastIndex = displays.lastIndex(where: { $0.jobID == job.id }) else { continue }
            displays[lastIndex].state = .active
        }
        return displays
    }

    private func eventDisplay(
        _ event: AgentEvent,
        jobNumbers: [UUID: Int],
        jobCount: Int
    ) -> AgentEventDisplay? {
        let prefix = jobPrefix(for: event.jobID, jobNumbers: jobNumbers, jobCount: jobCount)
        let title: String
        let detail: String
        let state: AgentProgressState

        switch event.kind {
        case .taskCreated, .jobQueued, .attemptStarted, .attachmentChunkProvided,
             .artifactCreated, .waiting, .resultFinalized, .completed:
            return nil
        case .responseTextReceived:
            return nil
        case .toolRequested:
            title = prefix + toolProgressTitle(event.metadata["tool"])
            detail = ""
            state = .completed
        case .questionAsked:
            title = prefix + "Needs input"
            detail = event.message ?? ""
            state = .info
        case .questionAnswered:
            title = prefix + "Answer received"
            detail = ""
            state = .completed
        case .questionExpired:
            title = prefix + "Question expired"
            detail = ""
            state = .failed
        case .steeringQueued:
            title = prefix + "New direction queued"
            detail = event.message ?? ""
            state = .info
        case .steeringApplied:
            title = prefix + "Direction applied"
            detail = event.message ?? ""
            state = .completed
        case .cancellationRequested:
            title = prefix + "Stopping"
            detail = ""
            state = .active
        case .cancelled:
            if event.metadata["result_id"] != nil { return nil }
            title = prefix + "Cancelled"
            detail = event.message ?? ""
            state = .failed
        case .failed:
            if event.metadata["result_id"] != nil { return nil }
            title = prefix + "Stopped"
            detail = event.message ?? ""
            state = .failed
        case .interrupted:
            title = prefix + "Paused"
            detail = event.message ?? ""
            state = .info
        case .restarted:
            title = prefix + "Restarted"
            detail = event.message ?? ""
            state = .completed
        }

        return AgentEventDisplay(
            id: event.id,
            jobID: event.jobID,
            kind: event.kind,
            title: title,
            detail: detail,
            state: state
        )
    }

    private func jobPrefix(
        for jobID: UUID?,
        jobNumbers: [UUID: Int],
        jobCount: Int
    ) -> String {
        guard jobCount > 1, let jobID, let number = jobNumbers[jobID] else { return "" }
        return "Agent \(number) · "
    }

    private func toolProgressTitle(_ rawToolName: String?) -> String {
        guard let rawToolName, let toolName = AgentToolName(rawValue: rawToolName) else {
            return "Working"
        }
        switch toolName {
        case .attachmentChunk:
            return "Reading attachment"
        case .runJavaScript:
            return "Running local analysis"
        case .artifact:
            return "Creating artifact"
        case .question:
            return "Preparing a question"
        case .finalResult:
            return "Finalizing result"
        }
    }

    private func cleanedProgressText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 700 else { return trimmed }
        return String(trimmed.prefix(700)) + "…"
    }

    private func resultPresentation(
        _ result: AgentResult
    ) -> (title: String, icon: String, color: Color) {
        switch result.status {
        case .completed:
            return result.partial
                ? ("Partial result", "circle.lefthalf.filled", DS.Colors.textPrimary)
                : ("Result", "checkmark.circle.fill", DS.Colors.success)
        case .cancelled:
            return ("Cancelled", "xmark.circle", DS.Colors.textTertiary)
        case .failed:
            return ("Stopped", "exclamationmark.triangle.fill", DS.Colors.warningText)
        case .interrupted:
            return ("Interrupted", "pause.circle", DS.Colors.warning)
        }
    }

    private func resultView(_ result: AgentResult, task: AgentTask) -> some View {
        let taskJobs = coordinator.jobs(for: task.id)
        let jobIndex = taskJobs.firstIndex { $0.id == result.jobID }
        let agentPrefix: String
        if taskJobs.count > 1, let jobIndex {
            agentPrefix = "Agent \(jobIndex + 1) · "
        } else {
            agentPrefix = ""
        }
        let presentation = resultPresentation(result)
        return VStack(alignment: .leading, spacing: 6) {
            Label(agentPrefix + presentation.title, systemImage: presentation.icon)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(presentation.color)

            Text(LocalizedStringKey(result.markdown))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DS.Colors.textSecondary)
                .textSelection(.enabled)

            if !result.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(result.sources.enumerated()), id: \.offset) { _, source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Label(source.title, systemImage: "link")
                                    .font(.system(size: 9, design: .rounded))
                            }
                            .foregroundStyle(DS.Colors.accentText)
                        }
                    }
                }
            }

            if !result.limitations.isEmpty {
                Text("Limitations: " + result.limitations.joined(separator: " · "))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            if !result.suggestedActions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(result.suggestedActions.enumerated()), id: \.offset) { _, action in
                        Label(action, systemImage: "arrow.right")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.Colors.borderSubtle))
    }

    private func artifactRow(_ artifact: AgentArtifact, task: AgentTask) -> some View {
        let taskJobs = coordinator.jobs(for: task.id)
        let jobIndex = taskJobs.firstIndex { $0.id == artifact.jobID }
        let agentPrefix: String
        if taskJobs.count > 1, let jobIndex {
            agentPrefix = "Agent \(jobIndex + 1) · "
        } else {
            agentPrefix = ""
        }
        return HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(DS.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Text(agentPrefix + artifact.mediaType)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer()
            Button("Export") { export(artifact) }
                .dsTextButtonStyle(fontSize: 9)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(DS.Colors.surface2))
    }

    private func jobGroupView(_ jobs: [AgentJob]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GROUP · \(jobs.count) AGENTS")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(DS.Colors.textTertiary)

            ForEach(jobs) { job in
                HStack(spacing: 7) {
                    if job.status == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 10, height: 10)
                    } else {
                        Circle()
                            .fill(jobStatusColor(job.status))
                            .frame(width: 6, height: 6)
                            .frame(width: 10, height: 10)
                    }
                    Text(job.instruction)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    Text(job.status.rawValue.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
            }
        }
    }

    private func threadRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Colors.textSecondary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func noticeBanner(_ notice: AgentNotice) -> some View {
        Button {
            coordinator.selectedTaskID = notice.taskID
            coordinator.dismissNotice(id: notice.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: noticeIcon(notice.kind))
                    .foregroundStyle(noticeColor(notice.kind))
                Text(notice.title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text(notice.detail)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(DS.Colors.surface3))
            .overlay(Capsule().stroke(DS.Colors.borderStrong))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func skillChip(_ skill: SkillIdentity) -> some View {
        let isSelected = draftSkillIDs.contains(skill.id)
        return Button {
            if isSelected {
                draftSkillIDs.remove(skill.id)
            } else {
                draftSkillIDs.insert(skill.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: skill.icon)
                Text(skill.displayName)
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(Capsule().fill(isSelected ? DS.Colors.surface4 : DS.Colors.surface2))
            .overlay(Capsule().stroke(isSelected ? DS.Colors.borderStrong : DS.Colors.borderSubtle))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func attachmentChip(_ url: URL) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
            Text(url.lastPathComponent)
                .lineLimit(1)
            Button {
                draftAttachmentURLs.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 8, design: .rounded))
        .foregroundStyle(DS.Colors.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(Capsule().fill(DS.Colors.surface2))
    }

    private var activeTasks: [AgentTask] {
        coordinator.tasks.filter { [.queued, .running, .waiting].contains($0.status) }
    }

    private var recentTerminalTasks: [AgentTask] {
        coordinator.recentTasks.filter { ![.queued, .running, .waiting].contains($0.status) }
    }

    private var olderHistoryTasks: [AgentTask] {
        let recentIDs = Set(coordinator.recentTasks.map(\.id))
        return coordinator.historyTasks.filter { !recentIDs.contains($0.id) }
    }

    private var availableSkills: [SkillIdentity] {
        companionManager.enabledSkillIDs.compactMap { skillID in
            guard let skill = SkillRegistry.identity(forID: skillID),
                  skill.compatibleAgentTypes.isEmpty
                    || skill.compatibleAgentTypes.contains(where: { $0.caseInsensitiveCompare("general") == .orderedSame })
            else { return nil }
            return skill
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var availabilityText: String {
        switch coordinator.availability {
        case .loading:
            return "Loading local task state…"
        case .available:
            return "Ready for research, synthesis, artifacts, and local analysis"
        case .unavailable:
            return "Temporarily unavailable"
        }
    }

    private func submitDraft() async {
        errorMessage = nil
        let snapshots = availableSkills
            .filter { draftSkillIDs.contains($0.id) }
            .map { AgentSkillSnapshot(id: $0.id, displayName: $0.displayName, instructions: $0.instructions) }
        do {
            let task = try await coordinator.submit(
                instruction: draftInstruction,
                source: AgentSource(kind: .text),
                attachmentURLs: draftAttachmentURLs,
                skillSnapshots: snapshots,
                childInstructions: draftChildInstructions
            )
            resetDraft()
            isCreatingTask = false
            coordinator.selectedTaskID = task.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendComposer(_ task: AgentTask, question: AgentQuestion?) async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if let question {
                try await coordinator.answer(questionID: question.id, answer: text)
            } else {
                try await coordinator.steer(taskID: task.id, text: text)
            }
            composerText = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel(_ task: AgentTask) async {
        do {
            try await coordinator.cancel(taskID: task.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restart(_ task: AgentTask) async {
        do {
            try await coordinator.restart(taskID: task.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ task: AgentTask) async {
        defer { taskPendingDeletion = nil }
        do {
            try await coordinator.delete(taskID: task.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(_ artifact: AgentArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            try artifact.content.write(to: destinationURL, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendDraftAttachments(_ urls: [URL]) {
        for url in urls where !draftAttachmentURLs.contains(url) {
            draftAttachmentURLs.append(url)
        }
    }

    private func ingestDraftDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let urlString = String(data: data, encoding: .utf8),
                      let url = URL(string: urlString) else { return }
                DispatchQueue.main.async { appendDraftAttachments([url]) }
            }
        }
    }

    private func resetDraft() {
        draftInstruction = ""
        draftChildInstructions = []
        draftAttachmentURLs = []
        draftSkillIDs = []
    }

    private var canSubmitDraft: Bool {
        guard !draftInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return draftChildInstructions.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func canCompose(_ status: AgentTaskStatus) -> Bool {
        [.queued, .running, .waiting].contains(status)
    }

    private func statusIcon(_ status: AgentTaskStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "waveform.path"
        case .waiting: return "questionmark.bubble"
        case .completed: return "checkmark"
        case .cancelled: return "xmark"
        case .failed: return "exclamationmark"
        case .interrupted: return "pause"
        }
    }

    private func statusColor(_ status: AgentTaskStatus) -> Color {
        switch status {
        case .completed: return DS.Colors.success
        case .waiting: return DS.Colors.warning
        case .failed: return DS.Colors.warningText
        default: return DS.Colors.textSecondary
        }
    }

    private func jobStatusColor(_ status: AgentJobStatus) -> Color {
        switch status {
        case .completed: return DS.Colors.success
        case .waiting: return DS.Colors.warning
        case .failed: return DS.Colors.warningText
        default: return DS.Colors.textTertiary
        }
    }

    private func noticeIcon(_ kind: AgentNoticeKind) -> String {
        switch kind {
        case .completed: return "checkmark.circle.fill"
        case .needsInput: return "questionmark.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func noticeColor(_ kind: AgentNoticeKind) -> Color {
        switch kind {
        case .completed: return DS.Colors.success
        case .needsInput: return DS.Colors.warning
        case .failed: return DS.Colors.warningText
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct AgentEventDisplay: Identifiable {
    let id: UUID
    let jobID: UUID?
    let kind: AgentEventKind
    let title: String
    let detail: String
    var state: AgentProgressState
}

private enum AgentProgressState {
    case active
    case completed
    case failed
    case info
}
