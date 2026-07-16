//
//  DictationModels.swift
//  leanring-buddy
//
//  Content-minimizing types shared by the dedicated dictation path. These types
//  deliberately contain only the app category and safe insertion facts needed by
//  the Worker; raw AX values, selections, titles, and URLs never leave the device.
//

import Foundation

enum DictationSurfaceKind: String, CaseIterable, Codable, Identifiable {
    case email
    case chat
    case document
    case code
    case terminal
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .chat: return "Chat"
        case .document: return "Document"
        case .code: return "Code"
        case .terminal: return "Terminal"
        case .generic: return "Text field"
        }
    }
}
enum DictationFormattingMode: String, CaseIterable, Codable, Identifiable {
    case literal
    case clean
    case smart

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .clean: return "Clean"
        case .smart: return "Smart"
        }
    }

    var detail: String {
        switch self {
        case .literal:
            return "Realtime model preserves literal wording and renders explicit commands only."
        case .clean:
            return "Realtime model applies conservative cleanup and formats clearly dictated items as a numbered list."
        case .smart:
            return "Realtime model applies app-aware polish and infers useful structure such as numbered lists."
        }
    }
}

struct DictationTargetPreparation: Equatable {
    let applicationName: String
    let applicationBundleIdentifier: String
    let surfaceKind: DictationSurfaceKind
    let hasSelection: Bool
    let isTerminal: Bool
}

struct DictationTranscriptionConfiguration: Equatable {
    let keyterms: [String]
    let surfaceKind: DictationSurfaceKind
    let formattingMode: DictationFormattingMode
}

struct DictationTranscription: Equatable {
    let text: String
    let realtimeFinalizationMilliseconds: Int
    let workerConnectionMilliseconds: Int
}

@MainActor
protocol DictationTranscriber: AnyObject {
    func start(configuration: DictationTranscriptionConfiguration) async throws
    func sendAudio(_ pcm16Chunk: Data)
    func finish() async throws -> DictationTranscription
    func cancel()
}

enum DictationSurfaceClassifier {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.kagi.kagimacOS",
    ]
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
    ]
    private static let codeBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
    ]
    private static let emailBundleIdentifiers: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "com.postbox-inc.postbox",
    ]
    private static let chatBundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.microsoft.teams2",
        "us.zoom.xos",
        "net.whatsapp.WhatsApp",
        "com.facebook.archon",
    ]
    private static let documentBundleIdentifiers: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "notion.id",
        "com.craftingking.IdeaSmith",
    ]

    /// `browserMetadata` is parsed only on-device and must be limited to browser
    /// chrome/AX labels. Callers never persist or send it to the Worker.
    static func classify(
        bundleIdentifier: String,
        applicationName: String,
        browserMetadata: [String] = []
    ) -> DictationSurfaceKind {
        if terminalBundleIdentifiers.contains(bundleIdentifier) { return .terminal }
        if codeBundleIdentifiers.contains(bundleIdentifier) { return .code }
        if emailBundleIdentifiers.contains(bundleIdentifier) { return .email }
        if chatBundleIdentifiers.contains(bundleIdentifier) { return .chat }
        if documentBundleIdentifiers.contains(bundleIdentifier) { return .document }

        guard browserBundleIdentifiers.contains(bundleIdentifier) else { return .generic }
        let browserContext = ([applicationName] + browserMetadata)
            .joined(separator: " ")
            .lowercased()
        if browserContext.contains("mail.google.com") || browserContext.contains("gmail") {
            return .email
        }
        if browserContext.contains("app.slack.com") || browserContext.contains("slack") {
            return .chat
        }
        if browserContext.contains("docs.google.com")
            || browserContext.contains("notion")
            || browserContext.contains("office.com") {
            return .document
        }
        if browserContext.contains("github.com")
            || browserContext.contains("gitlab.com")
            || browserContext.contains("codespaces") {
            return .code
        }
        return .generic
    }

    static func isBrowser(bundleIdentifier: String) -> Bool {
        browserBundleIdentifiers.contains(bundleIdentifier)
    }

    static func isTerminal(bundleIdentifier: String) -> Bool {
        terminalBundleIdentifiers.contains(bundleIdentifier)
    }
}

enum DictationGlossary {
    static let maximumTerms = 100
    static let maximumTermLength = 50

    static func keyterms(from editableText: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        let pieces = editableText.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        for piece in pieces {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maximumTermLength else { continue }
            let identity = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(identity).inserted else { continue }
            terms.append(term)
            if terms.count == maximumTerms { break }
        }
        return terms
    }
}
