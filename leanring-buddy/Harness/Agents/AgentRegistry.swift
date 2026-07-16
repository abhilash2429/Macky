//
//  AgentRegistry.swift
//  leanring-buddy
//

import Foundation

/// The General Agent is deliberately narrow in this slice. It can operate only on
/// copied local attachments and produce local artifacts/questions/results; it has no
/// tool contract for cloud state or external side effects.
struct AgentCapabilityPolicy: Codable, Equatable, Sendable {
    let permitsCloudState: Bool
    let permitsExternalEffects: Bool

    static let localOnly = AgentCapabilityPolicy(
        permitsCloudState: false,
        permitsExternalEffects: false
    )
}

struct AgentDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let model: AgentModel
    let capabilityPolicy: AgentCapabilityPolicy
    let toolContracts: [AgentToolContract]

    init(
        id: String,
        displayName: String,
        model: AgentModel,
        capabilityPolicy: AgentCapabilityPolicy,
        toolContracts: [AgentToolContract]
    ) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.capabilityPolicy = capabilityPolicy
        self.toolContracts = toolContracts
    }
}

nonisolated enum AgentRegistry {
    static let general = AgentDefinition(
        id: "general",
        displayName: "General Agent",
        model: .solMedium,
        capabilityPolicy: .localOnly,
        toolContracts: AgentToolContract.generalAgentContracts
    )

    static let registeredAgents = [general]

    static func definition(forID id: String) -> AgentDefinition? {
        registeredAgents.first { $0.id == id }
    }
}
