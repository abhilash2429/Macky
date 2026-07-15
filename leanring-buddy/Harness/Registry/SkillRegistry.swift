//
//  SkillRegistry.swift
//  leanring-buddy
//
//  Client-side catalog of Macky's Skills. Mirrors ConnectorRegistry.swift's role
//  for connectors: this is the single source of truth for skill identity (id,
//  display name, summary, icon, and which connectors it draws on).
//
//  A Skill is a functional agent capability, not a UI grouping: enabling one is
//  meant to contribute its `instructions` and expose its associated tools during
//  the realtime session's `session.update`. A Skill is NOT 1:1 with a connector
//  \u2014 it may use zero, one, or many connectors/tools, and a connector may be used
//  by many Skills (see the "Meeting Assistant" example below, which spans two).
//
//  This registry only covers identity/catalog. Whether a skill is enabled lives
//  in CompanionManager.enabledSkillIDs (UI-observable, persisted client-side).
//  Actually merging an enabled skill's instructions/tools into RealtimeClient's
//  session config is an intentionally separate, later milestone \u2014 do not wire
//  that up as a side effect of touching this file.
//

import Foundation

/// The identity of a Skill for catalog/browsing purposes.
struct SkillIdentity: Identifiable, Equatable {
    /// Stable catalog id, e.g. "meeting-assistant". Also the persistence key used
    /// by CompanionManager.enabledSkillIDs.
    let id: String
    /// Human-facing name, e.g. "Meeting Assistant".
    let displayName: String
    /// One-line description shown in the Skills window and (truncated) on Home.
    let summary: String
    /// SF Symbol name. Skills are abstract behaviors, not branded like connectors,
    /// so there's no bundled logo asset the way ConnectorRegistry has one.
    let icon: String
    /// ConnectorRegistry slugs this skill draws on, for "uses: ..." pills. A skill
    /// may reference zero connectors (e.g. a skill built only on local tools).
    let connectorSlugs: [String]
    /// System-prompt fragment contributed when this skill is enabled. Stored now
    /// so the catalog shape is ready for the future RealtimeClient wiring; not
    /// consumed anywhere yet.
    let instructions: String
}

enum SkillRegistry {
    /// The registered skill set. Deliberately a small, realistic v1 starter list
    /// covering MACKY.md's v1 integrations (calendar, gmail, slack, spotify,
    /// github) plus one zero-connector example (Research) \u2014 not meant to be
    /// exhaustive. Extend this list as new skills are designed.
    static let skills: [SkillIdentity] = [
        SkillIdentity(
            id: "meeting-assistant",
            displayName: "Meeting Assistant",
            summary: "Preps you before meetings using your calendar, email, and reminders.",
            icon: "calendar.badge.clock",
            connectorSlugs: ["googlecalendar", "gmail"],
            instructions: "When the user asks about an upcoming meeting, check their calendar for the event details, look for related email threads with the attendees, and surface anything they should know before joining."
        ),
        SkillIdentity(
            id: "email-assistant",
            displayName: "Email Assistant",
            summary: "Reads, drafts, and sends email from voice requests.",
            icon: "envelope.badge",
            connectorSlugs: ["gmail"],
            instructions: "Handle email requests end to end: read unread mail, summarize threads, and draft or send replies in the user's voice. Confirm the action was taken in one short clause after doing it, not before."
        ),
        SkillIdentity(
            id: "research",
            displayName: "Research",
            summary: "Looks things up and reads documents to answer open-ended questions.",
            icon: "magnifyingglass",
            connectorSlugs: [],
            instructions: "For open-ended or factual questions, gather information from the screen or attached documents before answering, and give a direct synthesized answer rather than a list of sources."
        ),
        SkillIdentity(
            id: "code-review",
            displayName: "Code Review",
            summary: "Checks pull request and issue status, and helps triage bugs.",
            icon: "chevron.left.forwardslash.chevron.right",
            connectorSlugs: ["github"],
            instructions: "When asked about repository status, check open issues and pull requests, summarize what's failing or blocked, and offer to create or update an issue."
        ),
        SkillIdentity(
            id: "team-updates",
            displayName: "Team Updates",
            summary: "Sends Slack updates and tracks Linear issues in one flow.",
            icon: "bubble.left.and.bubble.right",
            connectorSlugs: ["slack", "linear"],
            instructions: "When the user reports progress verbally, post the update to the right Slack channel and, if it corresponds to a tracked issue, move that issue's status in Linear to match."
        ),
        SkillIdentity(
            id: "music-control",
            displayName: "Music Control",
            summary: "Plays, pauses, and queues music without leaving the notch.",
            icon: "music.note",
            connectorSlugs: ["spotify"],
            instructions: "Handle playback requests (play, pause, skip, queue, volume) directly and briefly confirm what changed."
        )
    ]

    /// Looks up a skill identity by its catalog id.
    static func identity(forID id: String) -> SkillIdentity? {
        skills.first { $0.id == id }
    }
}
