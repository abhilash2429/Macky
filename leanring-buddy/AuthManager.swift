//
//  AuthManager.swift
//  leanring-buddy
//
//  Owns two related but distinct things:
//
//  1. UI auth (`phase`) — gates whether the panel shows AuthView or the main UI.
//     On launch this is `.authenticated` only if the Keychain holds an email-verified
//     session, or the user previously tapped "Skip for now". Otherwise AuthView shows,
//     where the user can submit their email (`requestMagicLink`); the Worker emails a
//     clickable link that bounces through `/auth/open` into the `Macky://auth?token=…`
//     deep link, which routes back through `handleIncomingURL` → `verify`.
//
//  2. Composio identity (`sessionToken` / `composioUserId`) — the credential every
//     Composio-facing Worker route (`/composio-config`, `/composio-connect`,
//     `/composio-connections`, `/spotify-play`) requires as `Authorization: Bearer
//     <sessionToken>`. This is deliberately independent of `phase`: `ensureSessionToken()`
//     transparently mints a no-login "anonymous" session (`POST /auth/anonymous`) the
//     first time anything needs one, so connectors work from the very first launch —
//     before, and without ever requiring, email auth. Completing email auth later
//     (`verify`) replaces the anonymous session with one whose `composioUserId` is the
//     email (stable across reinstalls/devices); it does not migrate connections made
//     under the old anonymous identity — Composio has no cross-user account transfer, and
//     today's single-operator setup makes that an acceptable tradeoff.
//

import Combine
import Foundation
import Security

extension Notification.Name {
    /// Posted when a `Macky://connected?toolkit=…` deep link arrives — Composio's OAuth
    /// `callback_url` bouncing the browser back into the app once a connector finishes
    /// linking. `CompanionManager` observes this to refresh the connectors grid
    /// immediately instead of waiting on the next panel `onAppear`.
    static let mackyConnectorConnected = Notification.Name("mackyConnectorConnected")
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    enum Phase: Equatable {
        case idle
        case sending
        case sent
        case verifying
        case authenticated
        case error(String)
    }

    @Published private(set) var phase: Phase
    /// The email the magic link was sent to — shown in the "check your email" state.
    @Published private(set) var pendingEmail: String?

    /// The Composio session token, present as soon as any session — anonymous or
    /// email — exists. Nil only before the very first `ensureSessionToken()` call
    /// resolves. Callers should use `ensureSessionToken()` rather than reading this
    /// directly, since it bootstraps one on demand.
    @Published private(set) var sessionToken: String?
    /// The identity behind `sessionToken`: either `"anon-<uuid>"` (no login) or the
    /// verified email. Purely informational for the UI — never used to authorize a
    /// Worker call directly; the Worker resolves identity from `sessionToken` itself.
    @Published private(set) var composioUserId: String?

    /// Base for the Worker's auth routes. Derived from the single shared host in
    /// `WorkerEndpoints` so self-hosting only requires changing it in one place.
    private let workerBaseURL = WorkerEndpoints.httpsBase
    private static let keychainService = "macky.session"
    private static let skippedAuthDefaultsKey = "macky.authSkippedForNow"

    /// Coalesces concurrent `ensureSessionToken()` callers (e.g. `RealtimeClient.connect()`
    /// and `CompanionManager.refreshConnectedToolkits()` both firing near launch) so they
    /// share one `/auth/anonymous` bootstrap instead of each minting their own identity.
    private var bootstrapTask: Task<String?, Never>?

    private init() {
        let existing = AuthManager.loadSession()
        sessionToken = existing?.sessionToken
        composioUserId = existing?.composioUserId
        let isEmailVerified = existing?.kind == "email"
        phase = isEmailVerified || AuthManager.hasSkippedAuth ? .authenticated : .idle
    }

    // MARK: - Session state

    /// True when the Keychain holds an email-verified session (as opposed to an
    /// anonymous, no-login one).
    var hasSession: Bool {
        AuthManager.loadSession()?.kind == "email"
    }

    private static var hasSkippedAuth: Bool {
        UserDefaults.standard.bool(forKey: skippedAuthDefaultsKey)
    }

    func skipAuthenticationForNow() {
        UserDefaults.standard.set(true, forKey: Self.skippedAuthDefaultsKey)
        pendingEmail = nil
        phase = .authenticated
    }

    // MARK: - Composio identity (independent of `phase`)

    /// Returns the current Composio session token, bootstrapping a fresh anonymous
    /// session if none exists yet. This is what makes connectors work from the very
    /// first launch — no login, no manual setup. Safe to call from anywhere (including
    /// non-MainActor contexts, via `await`); concurrent callers share one in-flight
    /// bootstrap. Returns nil only if the Worker is unreachable/misconfigured, in which
    /// case callers should proceed without Composio rather than block.
    func ensureSessionToken() async -> String? {
        if let sessionToken { return sessionToken }
        if let bootstrapTask { return await bootstrapTask.value }

        let task = Task<String?, Never> { [weak self] in
            await self?.bootstrapAnonymousSession()
        }
        bootstrapTask = task
        let token = await task.value
        bootstrapTask = nil
        return token
    }

    private func bootstrapAnonymousSession() async -> String? {
        do {
            let response: SessionResponse = try await post(path: "/auth/anonymous", body: [:])
            AuthManager.saveSession(
                sessionToken: response.sessionToken,
                composioUserId: response.composioUserId,
                kind: "anonymous",
                email: nil
            )
            sessionToken = response.sessionToken
            composioUserId = response.composioUserId
            return response.sessionToken
        } catch {
            print("⚠️ AuthManager: anonymous session bootstrap failed: \(error)")
            return nil
        }
    }

    // MARK: - Request a magic link

    func requestMagicLink(email: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@") else {
            phase = .error("Enter a valid email.")
            return
        }

        pendingEmail = trimmedEmail
        phase = .sending
        do {
            let _: MagicLinkResponse = try await post(
                path: "/auth/magic-link",
                body: ["email": trimmedEmail]
            )
            phase = .sent
        } catch {
            phase = .error("Couldn't send the link. Check your connection and try again.")
        }
    }

    /// Returns from the "check your email" state to the email input form.
    func resetToInput() {
        pendingEmail = nil
        phase = .idle
    }

    // MARK: - Incoming URL (Macky://auth?token=… and Macky://connected?toolkit=…)

    /// Entry point for the custom URL scheme. Routes `auth` links to token verification
    /// and `connected` links (Composio's post-OAuth bounce-back) to a notification that
    /// `CompanionManager` uses to refresh the connectors grid.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "macky",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }

        switch url.host?.lowercased() {
        case "auth":
            // The URL can be delivered twice (Apple Event + application(_:open:)).
            // Ignore re-entry so a one-time token isn't verified a second time, which
            // would fail and flip an already-authenticated session into an error.
            guard phase != .verifying, phase != .authenticated,
                  let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
                  !token.isEmpty else {
                return
            }
            Task { await verify(token: token) }

        case "connected":
            NotificationCenter.default.post(name: .mackyConnectorConnected, object: nil)

        default:
            break
        }
    }

    func verify(token: String) async {
        phase = .verifying
        do {
            let response: SessionResponse = try await post(
                path: "/auth/verify",
                body: ["token": token]
            )
            // The Worker returns composioUserId == the email. This replaces any
            // anonymous session that was previously active.
            AuthManager.saveSession(
                sessionToken: response.sessionToken,
                composioUserId: response.composioUserId,
                kind: "email",
                email: response.composioUserId
            )
            sessionToken = response.sessionToken
            composioUserId = response.composioUserId
            phase = .authenticated
        } catch {
            phase = .error("That link is invalid or expired. Send a new one.")
        }
    }

    // MARK: - Networking

    private func post<Response: Decodable>(
        path: String,
        body: [String: String]
    ) async throws -> Response {
        guard let url = URL(string: workerBaseURL + path) else {
            throw AuthError.requestFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.requestFailed
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Keychain

    private struct StoredSession: Codable {
        let sessionToken: String
        let composioUserId: String
        /// `"anonymous"` or `"email"` — see the file header for what each means.
        let kind: String
        let email: String?
    }

    private static func saveSession(sessionToken: String, composioUserId: String, kind: String, email: String?) {
        let session = StoredSession(sessionToken: sessionToken, composioUserId: composioUserId, kind: kind, email: email)
        guard let data = try? JSONEncoder().encode(session) else { return }

        // Delete any existing item for this service first so SecItemAdd doesn't
        // fail with errSecDuplicateItem.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ] as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: composioUserId,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ AuthManager: Keychain save failed (\(status))")
        }
    }

    /// Reads the stored session by service alone, so we can detect a session on launch
    /// without knowing which identity it belongs to.
    private static func loadSession() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    /// Removes the stored session — handy for re-testing the auth flow. The next
    /// `ensureSessionToken()` call mints a fresh anonymous session.
    func clearSession() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.skippedAuthDefaultsKey)
        sessionToken = nil
        composioUserId = nil
        pendingEmail = nil
        phase = .idle
    }

    // MARK: - Models

    private struct MagicLinkResponse: Decodable {
        let ok: Bool
    }

    /// Shared response shape for both `/auth/anonymous` and `/auth/verify`.
    private struct SessionResponse: Decodable {
        let sessionToken: String
        let composioUserId: String
    }

    private enum AuthError: Error {
        case requestFailed
    }
}
