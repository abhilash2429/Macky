//
//  AuthManager.swift
//  leanring-buddy
//
//  Magic-link authentication. On launch the app checks `hasSession` (a Keychain
//  lookup); if there's no session it shows AuthView. The user submits their email
//  (requestMagicLink); the Worker emails them a clickable link that bounces through
//  `/auth/open` into the `Macky://auth?token=…` deep link. Opening it routes back
//  through `handleIncomingURL` → `verify`, which stores the session in the Keychain
//  and flips `phase` to `.authenticated`.
//

import Combine
import Foundation
import Security

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

    /// Base for the Worker's auth routes. Derived from the single shared host in
    /// `WorkerEndpoints` so self-hosting only requires changing it in one place.
    private let workerBaseURL = WorkerEndpoints.httpsBase
    private static let keychainService = "macky.session"

    private init() {
        phase = AuthManager.loadSession() != nil ? .authenticated : .idle
    }

    // MARK: - Session state

    /// True when a session blob is present in the Keychain.
    var hasSession: Bool {
        AuthManager.loadSession() != nil
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

    // MARK: - Incoming URL (Macky://auth?token=…)

    /// Entry point for the custom URL scheme. Extracts the token and verifies it.
    func handleIncomingURL(_ url: URL) {
        // The URL can be delivered twice (Apple Event + application(_:open:)).
        // Ignore re-entry so a one-time token isn't verified a second time, which
        // would fail and flip an already-authenticated session into an error.
        guard phase != .verifying, phase != .authenticated else { return }

        guard url.scheme?.lowercased() == "macky",
              url.host?.lowercased() == "auth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return
        }
        Task { await verify(token: token) }
    }

    func verify(token: String) async {
        phase = .verifying
        do {
            let response: VerifyResponse = try await post(
                path: "/auth/verify",
                body: ["token": token]
            )
            // The Worker returns composioUserId == the email, used as the Keychain account.
            AuthManager.saveSession(
                jwt: response.sessionJWT,
                composioUserId: response.composioUserId,
                email: response.composioUserId
            )
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
        let jwt: String
        let composioUserId: String
        let email: String
    }

    private static func saveSession(jwt: String, composioUserId: String, email: String) {
        let session = StoredSession(jwt: jwt, composioUserId: composioUserId, email: email)
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
            kSecAttrAccount as String: email,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ AuthManager: Keychain save failed (\(status))")
        }
    }

    /// Reads the stored session by service alone, so we can detect a session on launch
    /// without knowing which email it belongs to.
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

    /// Removes the stored session — handy for re-testing the auth flow.
    func clearSession() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService
        ] as CFDictionary)
        pendingEmail = nil
        phase = .idle
    }

    // MARK: - Models

    private struct MagicLinkResponse: Decodable {
        let ok: Bool
    }

    private struct VerifyResponse: Decodable {
        let sessionJWT: String
        let composioUserId: String
    }

    private enum AuthError: Error {
        case requestFailed
    }
}
