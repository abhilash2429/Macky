//
//  AgentAPIClient.swift
//  leanring-buddy
//

import Foundation

/// REST/SSE transport only. Task state remains in `AgentEncryptedPersistence`; this
/// client neither writes cloud task state nor exposes external-effect tool contracts.
final class AgentAPIClient: AgentAPIServing, @unchecked Sendable {
    private let baseURL: URL
    private let urlSession: URLSession
    private let sessionTokenProvider: AgentSessionTokenProviding

    init(
        baseURL: URL = URL(string: WorkerEndpoints.httpsBase)!,
        urlSession: URLSession? = nil,
        sessionTokenProvider: AgentSessionTokenProviding = AgentAuthSessionTokenProvider()
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession ?? Self.makeURLSession()
        self.sessionTokenProvider = sessionTokenProvider
    }

    func fetchConfiguration(for definition: AgentDefinition) async throws -> AgentRemoteConfiguration {
        _ = definition
        let url = baseURL.appendingPathComponent("agent-config")

        let data = try await configurationData(url: url, allowSessionRefresh: true)
        do {
            return try JSONDecoder().decode(AgentRemoteConfiguration.self, from: data)
        } catch {
            throw AgentAPIClientError.invalidConfiguration
        }
    }

    func streamResponse(_ agentRequest: AgentResponseRequest) async -> AsyncThrowingStream<AgentResponseStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let responseTask = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: AgentAPIClientError.deallocated)
                    return
                }
                do {
                    try await self.consumeResponseStream(
                        agentRequest,
                        continuation: continuation,
                        allowSessionRefresh: true
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in responseTask.cancel() }
        }
    }

    private static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        // The Worker sends an SSE comment every ten seconds. This longer inactivity
        // window covers connection setup without imposing the default short resource limit.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    private func configurationData(url: URL, allowSessionRefresh: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let authorizationToken = await addAuthorization(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        if Self.statusCode(response) == 401,
           allowSessionRefresh,
           let authorizationToken,
           await sessionTokenProvider.refreshSessionToken(rejecting: authorizationToken) != nil {
            return try await configurationData(url: url, allowSessionRefresh: false)
        }
        try validate(response: response)
        return data
    }

    private func consumeResponseStream(
        _ agentRequest: AgentResponseRequest,
        continuation: AsyncThrowingStream<AgentResponseStreamEvent, Error>.Continuation,
        allowSessionRefresh: Bool
    ) async throws {
        let url = baseURL.appendingPathComponent("agent-response")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(agentRequest)
        let authorizationToken = await addAuthorization(to: &request)

        let (bytes, response) = try await urlSession.bytes(for: request)
        if Self.statusCode(response) == 401,
           allowSessionRefresh,
           let authorizationToken,
           await sessionTokenProvider.refreshSessionToken(rejecting: authorizationToken) != nil {
            try await consumeResponseStream(
                agentRequest,
                continuation: continuation,
                allowSessionRefresh: false
            )
            return
        }
        try validate(response: response)
        if let httpResponse = response as? HTTPURLResponse,
           let requestID = httpResponse.value(forHTTPHeaderField: "X-Macky-Request-ID") {
            print("🧠 AgentAPIClient: response stream opened requestID=\(requestID)")
        }

        var dataLines: [String] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                try yieldSSEEvent(from: dataLines, to: continuation)
                dataLines = []
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        try yieldSSEEvent(from: dataLines, to: continuation)
    }

    private func addAuthorization(to request: inout URLRequest) async -> String? {
        guard let sessionToken = await sessionTokenProvider.sessionToken(), !sessionToken.isEmpty else {
            return nil
        }
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        return sessionToken
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentAPIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentAPIClientError.unsuccessfulResponse(statusCode: httpResponse.statusCode)
        }
    }

    private static func statusCode(_ response: URLResponse) -> Int? {
        (response as? HTTPURLResponse)?.statusCode
    }

    private func yieldSSEEvent(
        from dataLines: [String],
        to continuation: AsyncThrowingStream<AgentResponseStreamEvent, Error>.Continuation
    ) throws {
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        guard payload != "[DONE]" else { return }
        guard let data = payload.data(using: .utf8) else {
            throw AgentAPIClientError.invalidStreamEvent
        }
        do {
            continuation.yield(try JSONDecoder().decode(AgentResponseStreamEvent.self, from: data))
        } catch {
            throw AgentAPIClientError.invalidStreamEvent
        }
    }
}

/// Keeps the existing session bootstrap behind a small injectable protocol. This is
/// the only General Agent reference to auth; it does not alter AuthManager itself.
struct AgentAuthSessionTokenProvider: AgentSessionTokenProviding {
    func sessionToken() async -> String? {
        let authManager = await MainActor.run { AuthManager.shared }
        return await authManager.ensureSessionToken()
    }

    func refreshSessionToken(rejecting rejectedToken: String) async -> String? {
        let authManager = await MainActor.run { AuthManager.shared }
        return await authManager.refreshSessionToken(rejecting: rejectedToken)
    }
}

actor AgentFakeAPIClient: AgentAPIServing {
    private var configuration: AgentRemoteConfiguration
    private var responseBatches: [[AgentResponseStreamEvent]]
    private var recordedRequests: [AgentResponseRequest] = []

    init(
        configuration: AgentRemoteConfiguration,
        responseBatches: [[AgentResponseStreamEvent]] = []
    ) {
        self.configuration = configuration
        self.responseBatches = responseBatches
    }

    func fetchConfiguration(for definition: AgentDefinition) async throws -> AgentRemoteConfiguration {
        configuration
    }

    func streamResponse(_ request: AgentResponseRequest) async -> AsyncThrowingStream<AgentResponseStreamEvent, Error> {
        recordedRequests.append(request)
        let events = responseBatches.isEmpty ? [] : responseBatches.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func enqueue(_ events: [AgentResponseStreamEvent]) {
        responseBatches.append(events)
    }

    func requests() -> [AgentResponseRequest] {
        recordedRequests
    }
}

@MainActor
final class AgentFakeJavaScriptExecutor: AgentJavaScriptExecuting {
    private let result: AgentJavaScriptExecutionResult
    private var requests: [AgentJavaScriptExecutionRequest] = []

    init(result: AgentJavaScriptExecutionResult = AgentJavaScriptExecutionResult(output: Data("null".utf8))) {
        self.result = result
    }

    func execute(_ request: AgentJavaScriptExecutionRequest) async throws -> AgentJavaScriptExecutionResult {
        requests.append(request)
        return result
    }

    func executedRequests() -> [AgentJavaScriptExecutionRequest] {
        requests
    }
}

enum AgentAPIClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case unsuccessfulResponse(statusCode: Int)
    case invalidConfiguration
    case invalidStreamEvent
    case deallocated

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The General Agent Worker URL is invalid."
        case .invalidResponse:
            return "The General Agent Worker returned an invalid HTTP response."
        case .unsuccessfulResponse(let statusCode):
            return "The General Agent Worker request failed with HTTP \(statusCode)."
        case .invalidConfiguration:
            return "The General Agent Worker returned an invalid configuration."
        case .invalidStreamEvent:
            return "The General Agent Worker returned an invalid stream event."
        case .deallocated:
            return "The General Agent API client was released during a request."
        }
    }
}
