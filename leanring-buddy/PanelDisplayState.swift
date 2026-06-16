//
//  PanelDisplayState.swift
//  leanring-buddy
//
//  The single source of truth for what the open notch panel is showing. Lives on
//  CompanionManager (@Published) and is observed by NotchContainerView / AurenPanel.
//  Driving all content from one enum keeps the panel's "what am I displaying"
//  question in one place — file drops, model output for review, the connectors /
//  settings surfaces, and the default idle dashboard all flow through here.
//

import Foundation

/// What kind of content the model pushed up for review. Drives the card's header
/// badge and (later) how Approve routes the action.
enum PanelOutputType: Equatable {
    case emailDraft
    case messageDraft
    case genericText

    var badgeLabel: String {
        switch self {
        case .emailDraft:   return "Draft Email"
        case .messageDraft: return "Draft Message"
        case .genericText:  return "For Review"
        }
    }
}

/// What the open panel is currently displaying. `idle` is the default dashboard
/// (calendar / reminders / now playing / recent activity); the other cases each
/// take over the whole content area.
enum PanelDisplayState: Equatable {
    case idle
    case modelOutput(content: String, type: PanelOutputType)
    case fileDrop(files: [URL])
    case connectors
    case settings
    // Session 3 will add `onboarding` / `auth` cases here.
}
