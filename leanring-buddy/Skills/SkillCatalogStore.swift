//
//  SkillCatalogStore.swift
//  leanring-buddy
//
//  Observable local store for the standalone Skills window. It delegates the
//  actual JSON persistence to SkillRegistry so existing catalog callers and the
//  window always read the same definitions.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class SkillCatalogStore: ObservableObject {
    @Published private(set) var userSkills: [SkillIdentity]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SkillRegistry.migrateEnabledSkillIDs(defaults: defaults)
        self.userSkills = SkillRegistry.userSkillDefinitions(defaults: defaults)
    }

    var allSkills: [SkillIdentity] {
        SkillRegistry.builtInSkills + userSkills
    }

    func save(_ skill: SkillDefinition) throws {
        try SkillRegistry.saveUserSkill(skill, defaults: defaults)
        reload()
    }

    func delete(skillID: String) throws {
        try SkillRegistry.deleteUserSkill(withID: skillID, defaults: defaults)
        reload()
    }

    func reload() {
        userSkills = SkillRegistry.userSkillDefinitions(defaults: defaults)
    }
}

/// Inject this protocol from the app's future AI integration or from tests.
/// The Skills slice deliberately owns no network client and has no direct
/// knowledge of a provider or transport.
protocol SkillDraftingProvider {
    func draftSkill(for prompt: String) async throws -> SkillDraft
}

struct ClosureSkillDraftingProvider: SkillDraftingProvider {
    let draft: (String) async throws -> SkillDraft

    func draftSkill(for prompt: String) async throws -> SkillDraft {
        try await draft(prompt)
    }
}
