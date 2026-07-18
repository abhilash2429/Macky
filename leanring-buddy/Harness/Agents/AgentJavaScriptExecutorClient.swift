import Foundation

enum AgentJavaScriptExecutorError: LocalizedError, Equatable {
    case invalidRequest(String)
    case executorBusy
    case executionFailed(code: String, message: String)
    case timedOut
    case serviceInterrupted
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        case .executorBusy:
            return "The local JavaScript executor is already busy."
        case .executionFailed(_, let message):
            return message
        case .timedOut:
            return "The local JavaScript execution timed out."
        case .serviceInterrupted:
            return "The local JavaScript executor stopped unexpectedly."
        case .invalidResponse:
            return "The local JavaScript executor returned an invalid response."
        }
    }
}

@MainActor
final class AgentJavaScriptExecutorClient: AgentJavaScriptExecuting {
    static let shared = AgentJavaScriptExecutorClient()

    fileprivate static let serviceName = "com.speedmac.Macky.AgentExecutor"
    fileprivate static let executionTimeoutMilliseconds = 5_000
    // The helper is single-flight, so queue locally before opening an XPC connection.
    private static let executionGate = AgentJavaScriptExecutionGate()

    func execute(
        _ request: AgentJavaScriptExecutionRequest
    ) async throws -> AgentJavaScriptExecutionResult {
        let validatedRequest = try ValidatedExecutionRequest(request)
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(validatedRequest.wireRequest)
        } catch {
            throw AgentJavaScriptExecutorError.invalidRequest(
                "The JavaScript execution request could not be encoded."
            )
        }
        guard requestData.count <= AgentJavaScriptExecutorLimits.maximumWireRequestBytes else {
            throw AgentJavaScriptExecutorError.invalidRequest(
                "The JavaScript execution request exceeded 4 MiB."
            )
        }

        let pendingExecution = PendingAgentJavaScriptExecution(
            requestIdentifier: request.id,
            timeoutMilliseconds: Self.executionTimeoutMilliseconds
        )
        let executionLease = try await Self.executionGate.acquire()
        defer { executionLease.release() }

        let responseData = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await pendingExecution.waitForResponse(requestData: requestData)
        } onCancel: {
            Task { @MainActor in
                pendingExecution.cancelForTask()
            }
        }
        try Task.checkCancellation()
        return try Self.decodeResponse(
            responseData,
            expectedRequestIdentifier: request.id
        )
    }

    private static func decodeResponse(
        _ responseData: Data,
        expectedRequestIdentifier: UUID
    ) throws -> AgentJavaScriptExecutionResult {
        guard !responseData.isEmpty,
              responseData.count <= AgentJavaScriptExecutorLimits.maximumWireResponseBytes,
              let response = try? JSONDecoder().decode(
                AgentJavaScriptExecutorWireResponse.self,
                from: responseData
              ),
              response.requestIdentifier == expectedRequestIdentifier.uuidString else {
            throw AgentJavaScriptExecutorError.invalidResponse
        }

        switch response.status {
        case "success":
            guard response.artifacts.count <= AgentJavaScriptExecutorLimits.maximumArtifactCount else {
                throw AgentJavaScriptExecutorError.invalidResponse
            }

            let resultValue = try response.resultJSON.map {
                try Self.validatedOutputJSONObject(
                    $0,
                    maximumBytes: AgentJavaScriptExecutorLimits.maximumResultBytes
                )
            } ?? NSNull()
            var totalArtifactBytes = 0
            let artifacts = try response.artifacts.map { artifact in
                guard Self.isValidArtifactName(artifact.name) else {
                    throw AgentJavaScriptExecutorError.invalidResponse
                }
                let artifactJSONData = Data(artifact.json.utf8)
                let artifactValue = try Self.validatedOutputJSONObject(
                    artifact.json,
                    maximumBytes: AgentJavaScriptExecutorLimits.maximumArtifactBytes
                )
                totalArtifactBytes += artifactJSONData.count
                guard totalArtifactBytes
                    <= AgentJavaScriptExecutorLimits.maximumTotalArtifactBytes else {
                    throw AgentJavaScriptExecutorError.invalidResponse
                }
                return [
                    "name": artifact.name,
                    "value": artifactValue,
                ] as [String: Any]
            }
            let outputEnvelope: [String: Any] = [
                "result": resultValue,
                "artifacts": artifacts,
            ]
            guard JSONSerialization.isValidJSONObject(outputEnvelope),
                  let output = try? JSONSerialization.data(
                    withJSONObject: outputEnvelope,
                    options: [.sortedKeys]
                  ),
                  output.count <= AgentJavaScriptExecutorLimits.maximumDecodedOutputBytes else {
                throw AgentJavaScriptExecutorError.invalidResponse
            }
            return AgentJavaScriptExecutionResult(output: output)

        case "invalid_request":
            throw AgentJavaScriptExecutorError.invalidRequest(
                response.error?.message ?? "The executor rejected the JavaScript request."
            )
        case "busy":
            throw AgentJavaScriptExecutorError.executorBusy
        case "execution_failed":
            throw AgentJavaScriptExecutorError.executionFailed(
                code: response.error?.code ?? "execution_failed",
                message: response.error?.message ?? "JavaScript execution failed."
            )
        default:
            throw AgentJavaScriptExecutorError.invalidResponse
        }
    }

    private static func validatedOutputJSONObject(
        _ serializedValue: String,
        maximumBytes: Int
    ) throws -> Any {
        let data = Data(serializedValue.utf8)
        guard data.count <= maximumBytes else {
            throw AgentJavaScriptExecutorError.invalidResponse
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw AgentJavaScriptExecutorError.invalidResponse
        }
    }

    private static func isValidArtifactName(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && name.utf8.count <= AgentJavaScriptExecutorLimits.maximumArtifactNameBytes
            && !name.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

@MainActor
fileprivate final class AgentJavaScriptExecutionGate {
    private final class Waiter {
        enum State {
            case waiting
            case granted
            case cancelled
        }

        var continuation: CheckedContinuation<Lease, Error>?
        var state: State = .waiting
    }

    fileprivate final class Lease {
        private weak var gate: AgentJavaScriptExecutionGate?
        private var isReleased = false

        init(gate: AgentJavaScriptExecutionGate) {
            self.gate = gate
        }

        fileprivate func release() {
            guard !isReleased else { return }
            isReleased = true
            gate?.release()
        }
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []

    fileprivate func acquire() async throws -> Lease {
        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiter.state == .waiting else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                waiter.continuation = continuation
                guard !Task.isCancelled else {
                    waiter.state = .cancelled
                    waiter.continuation = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if isOccupied {
                    waiters.append(waiter)
                } else {
                    grant(waiter)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(waiter)
            }
        }
    }

    private func grant(_ waiter: Waiter) {
        guard waiter.state == .waiting,
              let continuation = waiter.continuation else {
            return
        }

        waiter.state = .granted
        waiter.continuation = nil
        isOccupied = true
        continuation.resume(returning: Lease(gate: self))
    }

    private func cancel(_ waiter: Waiter) {
        guard waiter.state == .waiting else { return }
        waiter.state = .cancelled

        if let index = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: index)
        }

        guard let continuation = waiter.continuation else { return }
        waiter.continuation = nil
        continuation.resume(throwing: CancellationError())
    }

    fileprivate func release() {
        guard isOccupied else { return }
        isOccupied = false

        while !waiters.isEmpty {
            let nextWaiter = waiters.removeFirst()
            guard nextWaiter.state == .waiting else { continue }
            grant(nextWaiter)
            return
        }
    }
}

@MainActor
private final class PendingAgentJavaScriptExecution {
    private let requestIdentifier: UUID
    private let timeoutMilliseconds: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var connection: NSXPCConnection?
    private var timeoutTask: Task<Void, Never>?
    private var terminalResult: Result<Data, Error>?
    private var executionDeadlineUptimeNanoseconds: UInt64?

    init(requestIdentifier: UUID, timeoutMilliseconds: Int) {
        self.requestIdentifier = requestIdentifier
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func waitForResponse(requestData: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            guard terminalResult == nil else {
                resume(continuation, with: terminalResult!)
                return
            }
            guard self.continuation == nil else {
                continuation.resume(throwing: AgentJavaScriptExecutorError.invalidResponse)
                return
            }

            self.continuation = continuation
            startConnection(requestData: requestData)
        }
    }

    func cancelForTask() {
        finish(.failure(CancellationError()), cancelRemoteExecution: true)
    }

    private func startConnection(requestData: Data) {
        let connection = NSXPCConnection(serviceName: AgentJavaScriptExecutorClient.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: (any MackyAgentExecutorClientXPCProtocol).self
        )
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionFailure()
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionFailure()
            }
        }
        self.connection = connection
        executionDeadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        connection.resume()

        let watchdogDelayMilliseconds = timeoutMilliseconds
            + AgentJavaScriptExecutorLimits.clientWatchdogGraceMilliseconds
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(watchdogDelayMilliseconds) * 1_000_000
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finish(
                .failure(AgentJavaScriptExecutorError.timedOut),
                cancelRemoteExecution: true
            )
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                self?.handleConnectionFailure()
            }
        }
        guard let executor = proxy as? MackyAgentExecutorClientXPCProtocol else {
            finish(
                .failure(AgentJavaScriptExecutorError.serviceInterrupted),
                cancelRemoteExecution: false
            )
            return
        }

        executor.executeRequest(requestData as NSData) { [weak self] responseData in
            Task { @MainActor in
                self?.finish(.success(responseData as Data), cancelRemoteExecution: false)
            }
        }
    }

    private func handleConnectionFailure() {
        guard terminalResult == nil else { return }
        let didReachExecutionDeadline = executionDeadlineUptimeNanoseconds.map {
            DispatchTime.now().uptimeNanoseconds >= $0
        } ?? false
        finish(
            .failure(
                didReachExecutionDeadline
                    ? AgentJavaScriptExecutorError.timedOut
                    : AgentJavaScriptExecutorError.serviceInterrupted
            ),
            cancelRemoteExecution: false
        )
    }

    private func finish(
        _ result: Result<Data, Error>,
        cancelRemoteExecution: Bool
    ) {
        guard terminalResult == nil else { return }
        terminalResult = result
        timeoutTask?.cancel()
        timeoutTask = nil

        let connection = self.connection
        self.connection = nil
        if cancelRemoteExecution,
           let executor = connection?.remoteObjectProxy as? MackyAgentExecutorClientXPCProtocol {
            executor.cancelRequest(requestIdentifier.uuidString as NSString)
        }
        connection?.invalidate()

        guard let continuation else { return }
        self.continuation = nil
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<Data, Error>,
        with result: Result<Data, Error>
    ) {
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

/// This declaration intentionally mirrors only the Objective-C selectors used by
/// the helper. No app model type is part of the XPC interface.
@objc private protocol MackyAgentExecutorClientXPCProtocol {
    func executeRequest(_ requestData: NSData, withReply reply: @escaping (NSData) -> Void)
    func cancelRequest(_ requestIdentifier: NSString)
}

private struct ValidatedExecutionRequest {
    let wireRequest: AgentJavaScriptExecutorWireRequest

    init(_ request: AgentJavaScriptExecutionRequest) throws {
        guard !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.source.utf8.count <= AgentJavaScriptExecutorLimits.maximumSourceBytes else {
            throw AgentJavaScriptExecutorError.invalidRequest(
                "JavaScript source must be non-empty and no larger than 256 KiB."
            )
        }
        let inputJSON: String
        if let input = request.input {
            guard input.count <= AgentJavaScriptExecutorLimits.maximumInputBytes,
                  let serializedInput = String(data: input, encoding: .utf8),
                  (try? JSONSerialization.jsonObject(
                    with: input,
                    options: .fragmentsAllowed
                  )) != nil else {
                throw AgentJavaScriptExecutorError.invalidRequest(
                    "Task input must be valid UTF-8 JSON no larger than 1 MiB."
                )
            }
            inputJSON = serializedInput
        } else {
            inputJSON = "null"
        }
        self.wireRequest = AgentJavaScriptExecutorWireRequest(
            requestIdentifier: request.id.uuidString,
            source: request.source,
            inputJSON: inputJSON,
            timeoutMilliseconds: AgentJavaScriptExecutorClient.executionTimeoutMilliseconds
        )
    }
}

private struct AgentJavaScriptExecutorWireRequest: Encodable {
    let requestIdentifier: String
    let source: String
    let inputJSON: String
    let timeoutMilliseconds: Int
}

private struct AgentJavaScriptExecutorWireArtifact: Decodable {
    let name: String
    let json: String
}

private struct AgentJavaScriptExecutorWireError: Decodable {
    let code: String
    let message: String
}

private struct AgentJavaScriptExecutorWireResponse: Decodable {
    let requestIdentifier: String
    let status: String
    let resultJSON: String?
    let artifacts: [AgentJavaScriptExecutorWireArtifact]
    let error: AgentJavaScriptExecutorWireError?
}

private enum AgentJavaScriptExecutorLimits {
    static let maximumWireRequestBytes = 4 * 1_024 * 1_024
    static let maximumWireResponseBytes = 6 * 1_024 * 1_024
    static let maximumSourceBytes = 256 * 1_024
    static let maximumInputBytes = 1_024 * 1_024
    static let maximumResultBytes = 256 * 1_024
    static let maximumArtifactCount = 16
    static let maximumArtifactNameBytes = 128
    static let maximumArtifactBytes = 512 * 1_024
    static let maximumTotalArtifactBytes = 2 * 1_024 * 1_024
    static let maximumDecodedOutputBytes = 3 * 1_024 * 1_024
    static let clientWatchdogGraceMilliseconds = 1_000
}
