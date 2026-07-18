//
//  SkillsWindowView.swift
//  leanring-buddy
//
//  Native SwiftUI surface for browsing, creating, reviewing, and managing
//  reusable Skills. Saved definitions are intentionally read-only: the only
//  revision path is Duplicate, which opens a new unsaved draft.
//

import AppKit
import SwiftUI

@MainActor
struct SkillsWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var catalog: SkillCatalogStore

    let draftingProvider: SkillDraftingProvider?

    @State private var searchText = ""
    @State private var skillDraft: SkillDraft?
    @State private var draftPrompt = ""
    @State private var isShowingDraftPrompt = false
    @State private var isDrafting = false
    @State private var selectedSkill: SkillIdentity?
    @State private var skillPendingDelete: SkillIdentity?
    @State private var errorMessage: String?

    init(
        companionManager: CompanionManager,
        catalog: SkillCatalogStore,
        draftingProvider: SkillDraftingProvider? = nil
    ) {
        self.companionManager = companionManager
        self.catalog = catalog
        self.draftingProvider = draftingProvider
    }

    private var filteredSkills: [SkillIdentity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.allSkills }

        return catalog.allSkills.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || $0.instructions.localizedCaseInsensitiveContains(query)
                || $0.compatibleAgentTypes.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
                .overlay(Color.white.opacity(0.1))

            if filteredSkills.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredSkills) { skill in
                            SkillRow(
                                skill: skill,
                                isEnabled: companionManager.isSkillEnabled(skill.id),
                                onToggle: { companionManager.toggleSkill(skill.id) },
                                onDetails: { selectedSkill = skill },
                                onDuplicate: { skillDraft = SkillDraft(copying: skill) },
                                onDelete: skill.isBuiltIn ? nil : { skillPendingDelete = skill }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(.ultraThinMaterial)
        .navigationTitle("Macky Skills")
        .sheet(item: $skillDraft) { draft in
            SkillEditorSheet(
                initialDraft: draft,
                onSave: saveDraft
            )
        }
        .sheet(isPresented: $isShowingDraftPrompt) {
            SkillDraftPromptSheet(
                prompt: $draftPrompt,
                isLoading: isDrafting,
                isAvailable: draftingProvider != nil,
                onCancel: { isShowingDraftPrompt = false },
                onSubmit: requestAIDraft
            )
        }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailSheet(
                skill: skill,
                isEnabled: companionManager.isSkillEnabled(skill.id),
                onToggle: { companionManager.toggleSkill(skill.id) },
                onDuplicate: { selectedSkill = nil; skillDraft = SkillDraft(copying: skill) }
            )
        }
        .alert(
            "Delete Skill?",
            isPresented: Binding(
                get: { skillPendingDelete != nil },
                set: { if !$0 { skillPendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                deletePendingSkill()
            }
            Button("Cancel", role: .cancel) {
                skillPendingDelete = nil
            }
        } message: {
            Text("\"\(skillPendingDelete?.name ?? "This Skill")\" will be removed from Macky. Built-in Skills cannot be deleted.")
        }
        .alert(
            "Skills",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown Skills error occurred.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Skills")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))

                Text("Reusable instructions for compatible agents")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Menu {
                Button {
                    skillDraft = SkillDraft()
                } label: {
                    Label("Create manually", systemImage: "square.and.pencil")
                }

                Button {
                    draftPrompt = ""
                    isShowingDraftPrompt = true
                } label: {
                    Label("Draft with AI", systemImage: "sparkles")
                }
                .disabled(draftingProvider == nil)
            } label: {
                Label("New", systemImage: "plus")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.4))

            TextField("Search skills", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(.white.opacity(0.9))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))

            Text(searchText.isEmpty ? "No Skills yet" : "No skills match “\(searchText)”")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if searchText.isEmpty {
                Text("Create a Skill manually or inject an AI drafting provider.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestAIDraft() {
        guard let draftingProvider = draftingProvider else {
            errorMessage = "AI drafting is not configured for this window."
            return
        }

        let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            errorMessage = "Describe the reusable Skill you want to draft."
            return
        }

        isDrafting = true
        Task { @MainActor in
            do {
                var generatedDraft = try await draftingProvider.draftSkill(for: prompt)
                generatedDraft.origin = .aiDraft
                isDrafting = false
                isShowingDraftPrompt = false
                skillDraft = generatedDraft
            } catch {
                isDrafting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveDraft(_ draft: SkillDraft) -> Bool {
        guard draft.validationError == nil else {
            errorMessage = draft.validationError
            return false
        }

        let skill = SkillDefinition.makeUserSkill(from: draft)
        do {
            try catalog.save(skill)
            // New Skills are enabled immediately. SkillRegistry now exposes the
            // saved id to the unchanged CompanionManager compatibility methods.
            companionManager.enableSkill(skill.id)
            skillDraft = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func deletePendingSkill() {
        guard let skill = skillPendingDelete else { return }
        skillPendingDelete = nil

        do {
            try catalog.delete(skillID: skill.id)
            companionManager.disableSkill(skill.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SkillRow: View {
    let skill: SkillIdentity
    let isEnabled: Bool
    let onToggle: () -> Void
    let onDetails: () -> Void
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(skill.name)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))

                    Text(skill.origin.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }

                Text(skill.description)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !skill.compatibleAgentTypes.isEmpty {
                    metadataPills(
                        values: skill.compatibleAgentTypes,
                        prefix: "Agent"
                    )
                }

                if !skill.connectorSlugs.isEmpty {
                    connectorPills
                }

                HStack(spacing: 8) {
                    Text("SHA \(String(skill.contentHash.prefix(8)))")
                    Text("•")
                    Text(skill.isBuiltIn ? "Bundled" : skill.createdAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                EnableToggleButton(isEnabled: isEnabled, action: onToggle)

                Menu {
                    Button("Details", action: onDetails)
                    Button("Duplicate to revise", action: onDuplicate)
                    if let onDelete = onDelete {
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .secondarySystemFill))
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: skill.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            )
    }

    private func metadataPills(values: [String], prefix: String) -> some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text("\(prefix): \(value)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
    }

    private var connectorPills: some View {
        HStack(spacing: 6) {
            ForEach(skill.connectorSlugs, id: \.self) { slug in
                if let identity = ConnectorRegistry.identity(forSlug: slug),
                   let logo = NSImage(named: identity.logoAssetName) {
                    HStack(spacing: 4) {
                        Image(nsImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                        Text(identity.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        }
    }
}

private struct EnableToggleButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isEnabled ? "Enabled" : "Enable")
                .font(.system(.footnote, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(isEnabled ? .white : .white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isEnabled ? Color.accentColor : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SkillDraftPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var prompt: String

    let isLoading: Bool
    let isAvailable: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Draft a Skill with AI")
                .font(.system(.title2, design: .rounded).weight(.semibold))

            Text("Describe the reusable instructions you want. The generated draft will open for review before anything is saved.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)

            TextEditor(text: $prompt)
                .font(.system(.body, design: .rounded))
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                )
                .frame(minHeight: 140)

            if !isAvailable {
                Label("No AI drafting provider is injected for this build.", systemImage: "info.circle")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button {
                    onSubmit()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Generate draft")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || !isAvailable || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SkillDraft
    @State private var compatibleAgentTypesText: String
    @State private var validationMessage: String?

    let onSave: (SkillDraft) -> Bool

    init(initialDraft: SkillDraft, onSave: @escaping (SkillDraft) -> Bool) {
        _draft = State(initialValue: initialDraft)
        _compatibleAgentTypesText = State(
            initialValue: initialDraft.compatibleAgentTypes.joined(separator: ", ")
        )
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.origin == .aiDraft ? "Review AI draft" : "Review Skill")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Saved Skills are immutable. You can duplicate this Skill later to revise it.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.description)
                TextField("Compatible agent types", text: $compatibleAgentTypesText)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft.instructions)
                        .font(.system(.body, design: .rounded))
                        .frame(minHeight: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                }
            }
            .formStyle(.grouped)

            if let validationMessage = validationMessage {
                Text(validationMessage)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.red)
            }

            HStack {
                Label(draft.origin.displayName, systemImage: "tag")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Save Skill") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private func save() {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.description = candidate.description.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.instructions = candidate.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.compatibleAgentTypes = compatibleAgentTypesText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let validationError = candidate.validationError else {
            if onSave(candidate) {
                dismiss()
            }
            return
        }

        validationMessage = validationError
    }
}

private struct SkillDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let skill: SkillIdentity
    let isEnabled: Bool
    let onToggle: () -> Void
    let onDuplicate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: skill.icon)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("\(skill.origin.displayName) • \(skill.isBuiltIn ? "Bundled" : skill.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Text(skill.description)
                .font(.system(.body, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(skill.instructions)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.body, design: .rounded))
                }
                .frame(maxHeight: 190)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                )
            }

            if !skill.compatibleAgentTypes.isEmpty {
                Text("Compatible agents: \(skill.compatibleAgentTypes.joined(separator: ", "))")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Text("Content hash: \(skill.contentHash)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button(isEnabled ? "Disable" : "Enable", action: onToggle)
                    .buttonStyle(.bordered)
                Button("Duplicate to revise", action: onDuplicate)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }
}
