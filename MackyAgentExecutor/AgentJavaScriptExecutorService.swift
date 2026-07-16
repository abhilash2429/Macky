import Darwin
import Foundation
import JavaScriptCore

final class AgentJavaScriptExecutorService: NSObject, MackyAgentExecutorXPCProtocol {
    private static let executionQueue = DispatchQueue(
        label: "com.speedmac.Macky.AgentExecutor.execution",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let stateLock = NSLock()
    private var activeRequestIdentifier: String?

    @objc func executeRequest(
        _ requestData: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        let request: ExecutorWireRequest
        do {
            request = try ExecutorWireRequest.decodeAndValidate(requestData)
        } catch let failure as ExecutorFailure {
            reply(ExecutorWireResponse.failure(
                requestIdentifier: failure.requestIdentifier ?? "",
                status: .invalidRequest,
                failure: failure
            ).encodedData() as NSData)
            return
        } catch {
            reply(ExecutorWireResponse.failure(
                requestIdentifier: "",
                status: .invalidRequest,
                failure: ExecutorFailure(
                    code: "invalid_request",
                    message: "The JavaScript execution request was malformed."
                )
            ).encodedData() as NSData)
            return
        }

        guard claimRequest(request.requestIdentifier) else {
            reply(ExecutorWireResponse.failure(
                requestIdentifier: request.requestIdentifier,
                status: .busy,
                failure: ExecutorFailure(
                    code: "executor_busy",
                    message: "This executor connection already has an active request."
                )
            ).encodedData() as NSData)
            return
        }

        guard ProcessExecutionCoordinator.shared.beginExecution(
            requestIdentifier: request.requestIdentifier,
            timeoutMilliseconds: request.timeoutMilliseconds
        ) else {
            releaseRequest(request.requestIdentifier)
            reply(ExecutorWireResponse.failure(
                requestIdentifier: request.requestIdentifier,
                status: .busy,
                failure: ExecutorFailure(
                    code: "executor_busy",
                    message: "The JavaScript executor is already running another request."
                )
            ).encodedData() as NSData)
            return
        }

        Self.executionQueue.async { [weak self] in
            guard let self else {
                ProcessExecutionCoordinator.shared.cancelExecution(
                    requestIdentifier: request.requestIdentifier
                )
                return
            }

            let response = Self.runJavaScript(request)
            guard ProcessExecutionCoordinator.shared.completeExecution(
                requestIdentifier: request.requestIdentifier
            ) else {
                return
            }
            self.releaseRequest(request.requestIdentifier)
            reply(response.encodedData() as NSData)
        }
    }

    @objc func cancelRequest(_ requestIdentifier: NSString) {
        let identifier = requestIdentifier as String
        guard isActiveRequest(identifier) else { return }
        ProcessExecutionCoordinator.shared.cancelExecution(requestIdentifier: identifier)
    }

    func cancelActiveExecution() {
        guard let requestIdentifier = currentRequestIdentifier() else { return }
        ProcessExecutionCoordinator.shared.cancelExecution(requestIdentifier: requestIdentifier)
    }

    private func claimRequest(_ requestIdentifier: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRequestIdentifier == nil else { return false }
        activeRequestIdentifier = requestIdentifier
        return true
    }

    private func releaseRequest(_ requestIdentifier: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if activeRequestIdentifier == requestIdentifier {
            activeRequestIdentifier = nil
        }
    }

    private func isActiveRequest(_ requestIdentifier: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRequestIdentifier == requestIdentifier
    }

    private func currentRequestIdentifier() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRequestIdentifier
    }

    private static func runJavaScript(_ request: ExecutorWireRequest) -> ExecutorWireResponse {
        autoreleasepool {
            let outputCollector = JavaScriptOutputCollector()
            guard let context = JSContext() else {
                return .failure(
                    requestIdentifier: request.requestIdentifier,
                    status: .executionFailed,
                    failure: ExecutorFailure(
                        code: "context_creation_failed",
                        message: "JavaScriptCore could not create an execution context."
                    )
                )
            }

            var exceptionMessage: String?
            context.exceptionHandler = { _, exception in
                exceptionMessage = boundedUTF8(
                    exception?.toString() ?? "JavaScript execution failed.",
                    maximumBytes: ExecutorLimits.maximumErrorMessageBytes
                )
            }

            let captureResultJSON: @convention(block) (NSString) -> Bool = { serializedValue in
                outputCollector.captureResultJSON(serializedValue as String)
            }
            let captureArtifactJSON: @convention(block) (NSString, NSString) -> Bool = {
                artifactName,
                serializedValue in
                outputCollector.captureArtifactJSON(
                    name: artifactName as String,
                    serializedValue: serializedValue as String
                )
            }

            context.setObject(
                request.inputJSON as NSString,
                forKeyedSubscript: "__mackySerializedInput" as NSString
            )
            context.setObject(
                captureResultJSON,
                forKeyedSubscript: "__mackyCaptureResultJSON" as NSString
            )
            context.setObject(
                captureArtifactJSON,
                forKeyedSubscript: "__mackyCaptureArtifactJSON" as NSString
            )

            _ = context.evaluateScript(Self.runtimeSetupSource)
            if let exceptionMessage {
                return .failure(
                    requestIdentifier: request.requestIdentifier,
                    status: .executionFailed,
                    failure: ExecutorFailure(
                        code: "runtime_setup_failed",
                        message: exceptionMessage
                    )
                )
            }

            exceptionMessage = nil
            let sourceURL = URL(
                string: "macky-agent://execution/\(request.requestIdentifier).js"
            )!
            _ = context.evaluateScript(request.source, withSourceURL: sourceURL)

            if let validationFailure = outputCollector.validationFailure {
                return .failure(
                    requestIdentifier: request.requestIdentifier,
                    status: .executionFailed,
                    failure: validationFailure
                )
            }
            if let exceptionMessage {
                return .failure(
                    requestIdentifier: request.requestIdentifier,
                    status: .executionFailed,
                    failure: ExecutorFailure(
                        code: "javascript_exception",
                        message: exceptionMessage
                    )
                )
            }

            return .success(
                requestIdentifier: request.requestIdentifier,
                resultJSON: outputCollector.resultJSON,
                artifacts: outputCollector.artifacts
            )
        }
    }

    private static let runtimeSetupSource = #"""
    (() => {
        "use strict";

        const serializedInput = globalThis.__mackySerializedInput;
        const captureResultJSON = globalThis.__mackyCaptureResultJSON;
        const captureArtifactJSON = globalThis.__mackyCaptureArtifactJSON;
        const stringify = JSON.stringify.bind(JSON);

        Reflect.deleteProperty(globalThis, "__mackySerializedInput");
        Reflect.deleteProperty(globalThis, "__mackyCaptureResultJSON");
        Reflect.deleteProperty(globalThis, "__mackyCaptureArtifactJSON");

        const deepFreeze = (value) => {
            if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
                for (const propertyName of Object.getOwnPropertyNames(value)) {
                    deepFreeze(value[propertyName]);
                }
                Object.freeze(value);
            }
            return value;
        };

        const taskInput = deepFreeze(JSON.parse(serializedInput));
        Object.defineProperty(globalThis, "input", {
            value: taskInput,
            writable: false,
            configurable: false,
            enumerable: true
        });
        Object.defineProperty(globalThis, "setResult", {
            value: (value) => {
                const serializedValue = stringify(value);
                if (serializedValue === undefined) {
                    throw new TypeError("setResult requires a JSON-serializable value.");
                }
                if (!captureResultJSON(serializedValue)) {
                    throw new RangeError("The result exceeded the executor output limits.");
                }
            },
            writable: false,
            configurable: false,
            enumerable: true
        });
        Object.defineProperty(globalThis, "emitArtifact", {
            value: (name, value) => {
                if (typeof name !== "string") {
                    throw new TypeError("emitArtifact requires a string name.");
                }
                const serializedValue = stringify(value);
                if (serializedValue === undefined) {
                    throw new TypeError("emitArtifact requires a JSON-serializable value.");
                }
                if (!captureArtifactJSON(name, serializedValue)) {
                    throw new RangeError("The artifact exceeded the executor output limits.");
                }
            },
            writable: false,
            configurable: false,
            enumerable: true
        });
    })();
    """#
}

private final class ProcessExecutionCoordinator {
    static let shared = ProcessExecutionCoordinator()

    private let stateLock = NSLock()
    private var activeRequestIdentifier: String?
    private var timeoutWorkItem: DispatchWorkItem?

    func beginExecution(requestIdentifier: String, timeoutMilliseconds: Int) -> Bool {
        stateLock.lock()
        guard activeRequestIdentifier == nil else {
            stateLock.unlock()
            return false
        }

        activeRequestIdentifier = requestIdentifier
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.terminateProcessIfActive(requestIdentifier: requestIdentifier)
        }
        self.timeoutWorkItem = timeoutWorkItem
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(timeoutMilliseconds),
            execute: timeoutWorkItem
        )
        return true
    }

    func completeExecution(requestIdentifier: String) -> Bool {
        stateLock.lock()
        guard activeRequestIdentifier == requestIdentifier else {
            stateLock.unlock()
            return false
        }

        activeRequestIdentifier = nil
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        stateLock.unlock()

        timeoutWorkItem?.cancel()
        return true
    }

    func cancelExecution(requestIdentifier: String) {
        terminateProcessIfActive(requestIdentifier: requestIdentifier)
    }

    private func terminateProcessIfActive(requestIdentifier: String) {
        stateLock.lock()
        guard activeRequestIdentifier == requestIdentifier else {
            stateLock.unlock()
            return
        }

        activeRequestIdentifier = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        stateLock.unlock()

        // Generated code may be in a non-cooperative infinite loop. Ending the
        // sandboxed helper is the hard cancellation boundary; launchd starts a
        // fresh helper for the next request.
        Darwin._exit(124)
    }
}

private final class JavaScriptOutputCollector {
    private(set) var resultJSON: String?
    private(set) var artifacts: [ExecutorWireArtifact] = []
    private(set) var validationFailure: ExecutorFailure?
    private var totalArtifactBytes = 0

    func captureResultJSON(_ serializedValue: String) -> Bool {
        guard validationFailure == nil else { return false }
        guard resultJSON == nil else {
            return fail(code: "result_already_set", message: "setResult may only be called once.")
        }
        guard validateJSON(
            serializedValue,
            maximumBytes: ExecutorLimits.maximumResultBytes,
            failureCode: "result_too_large",
            failureMessage: "The JavaScript result exceeded 256 KiB."
        ) else {
            return false
        }
        resultJSON = serializedValue
        return true
    }

    func captureArtifactJSON(name: String, serializedValue: String) -> Bool {
        guard validationFailure == nil else { return false }
        guard artifacts.count < ExecutorLimits.maximumArtifactCount else {
            return fail(
                code: "too_many_artifacts",
                message: "JavaScript emitted more than 16 artifacts."
            )
        }
        guard isValidArtifactName(name) else {
            return fail(
                code: "invalid_artifact_name",
                message: "Artifact names must be non-empty, bounded strings without control characters."
            )
        }
        guard validateJSON(
            serializedValue,
            maximumBytes: ExecutorLimits.maximumArtifactBytes,
            failureCode: "artifact_too_large",
            failureMessage: "A JavaScript artifact exceeded 512 KiB."
        ) else {
            return false
        }

        let artifactByteCount = serializedValue.utf8.count
        guard totalArtifactBytes + artifactByteCount <= ExecutorLimits.maximumTotalArtifactBytes else {
            return fail(
                code: "artifacts_too_large",
                message: "JavaScript artifacts exceeded the 2 MiB combined limit."
            )
        }

        totalArtifactBytes += artifactByteCount
        artifacts.append(ExecutorWireArtifact(name: name, json: serializedValue))
        return true
    }

    private func validateJSON(
        _ serializedValue: String,
        maximumBytes: Int,
        failureCode: String,
        failureMessage: String
    ) -> Bool {
        guard serializedValue.utf8.count <= maximumBytes else {
            return fail(code: failureCode, message: failureMessage)
        }
        guard let data = serializedValue.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
            return fail(
                code: "invalid_output_json",
                message: "JavaScript output was not valid JSON."
            )
        }
        return true
    }

    private func isValidArtifactName(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && name.utf8.count <= ExecutorLimits.maximumArtifactNameBytes
            && !name.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private func fail(code: String, message: String) -> Bool {
        validationFailure = ExecutorFailure(code: code, message: message)
        return false
    }
}

private struct ExecutorWireRequest: Decodable {
    let requestIdentifier: String
    let source: String
    let inputJSON: String
    let timeoutMilliseconds: Int

    static func decodeAndValidate(_ requestData: NSData) throws -> ExecutorWireRequest {
        guard requestData.length <= ExecutorLimits.maximumWireRequestBytes else {
            throw ExecutorFailure(
                code: "request_too_large",
                message: "The JavaScript execution request exceeded 4 MiB."
            )
        }

        let request: ExecutorWireRequest
        do {
            request = try JSONDecoder().decode(ExecutorWireRequest.self, from: requestData as Data)
        } catch {
            throw ExecutorFailure(
                code: "invalid_request",
                message: "The JavaScript execution request was malformed."
            )
        }

        guard UUID(uuidString: request.requestIdentifier) != nil else {
            throw ExecutorFailure(
                requestIdentifier: request.requestIdentifier,
                code: "invalid_request_identifier",
                message: "The execution request identifier was invalid."
            )
        }
        guard !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.source.utf8.count <= ExecutorLimits.maximumSourceBytes else {
            throw ExecutorFailure(
                requestIdentifier: request.requestIdentifier,
                code: "invalid_source",
                message: "JavaScript source must be non-empty and no larger than 256 KiB."
            )
        }
        guard request.inputJSON.utf8.count <= ExecutorLimits.maximumInputBytes,
              let inputData = request.inputJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: inputData, options: .fragmentsAllowed)) != nil else {
            throw ExecutorFailure(
                requestIdentifier: request.requestIdentifier,
                code: "invalid_input_json",
                message: "Task input must be valid JSON no larger than 1 MiB."
            )
        }
        guard ExecutorLimits.minimumTimeoutMilliseconds...ExecutorLimits.maximumTimeoutMilliseconds
            ~= request.timeoutMilliseconds else {
            throw ExecutorFailure(
                requestIdentifier: request.requestIdentifier,
                code: "invalid_timeout",
                message: "Execution timeout must be between 50 milliseconds and 30 seconds."
            )
        }
        return request
    }
}

private struct ExecutorWireArtifact: Codable {
    let name: String
    let json: String
}

private struct ExecutorWireError: Codable {
    let code: String
    let message: String
}

private struct ExecutorWireResponse: Encodable {
    enum Status: String, Encodable {
        case success
        case invalidRequest = "invalid_request"
        case busy
        case executionFailed = "execution_failed"
    }

    let requestIdentifier: String
    let status: Status
    let resultJSON: String?
    let artifacts: [ExecutorWireArtifact]
    let error: ExecutorWireError?

    static func success(
        requestIdentifier: String,
        resultJSON: String?,
        artifacts: [ExecutorWireArtifact]
    ) -> ExecutorWireResponse {
        ExecutorWireResponse(
            requestIdentifier: requestIdentifier,
            status: .success,
            resultJSON: resultJSON,
            artifacts: artifacts,
            error: nil
        )
    }

    static func failure(
        requestIdentifier: String,
        status: Status,
        failure: ExecutorFailure
    ) -> ExecutorWireResponse {
        ExecutorWireResponse(
            requestIdentifier: requestIdentifier,
            status: status,
            resultJSON: nil,
            artifacts: [],
            error: ExecutorWireError(
                code: failure.code,
                message: boundedUTF8(
                    failure.message,
                    maximumBytes: ExecutorLimits.maximumErrorMessageBytes
                )
            )
        )
    }

    func encodedData() -> Data {
        if let data = try? JSONEncoder().encode(self),
           data.count <= ExecutorLimits.maximumWireResponseBytes {
            return data
        }

        let fallback = ExecutorWireResponse(
            requestIdentifier: requestIdentifier,
            status: .executionFailed,
            resultJSON: nil,
            artifacts: [],
            error: ExecutorWireError(
                code: "response_too_large",
                message: "The executor response exceeded its transport limit."
            )
        )
        return (try? JSONEncoder().encode(fallback)) ?? Data()
    }
}

private struct ExecutorFailure: Error {
    let requestIdentifier: String?
    let code: String
    let message: String

    init(requestIdentifier: String? = nil, code: String, message: String) {
        self.requestIdentifier = requestIdentifier
        self.code = code
        self.message = message
    }
}

private enum ExecutorLimits {
    static let maximumWireRequestBytes = 4 * 1_024 * 1_024
    static let maximumWireResponseBytes = 6 * 1_024 * 1_024
    static let maximumSourceBytes = 256 * 1_024
    static let maximumInputBytes = 1_024 * 1_024
    static let maximumResultBytes = 256 * 1_024
    static let maximumArtifactCount = 16
    static let maximumArtifactNameBytes = 128
    static let maximumArtifactBytes = 512 * 1_024
    static let maximumTotalArtifactBytes = 2 * 1_024 * 1_024
    static let maximumErrorMessageBytes = 4 * 1_024
    static let minimumTimeoutMilliseconds = 50
    static let maximumTimeoutMilliseconds = 30_000
}

private func boundedUTF8(_ string: String, maximumBytes: Int) -> String {
    guard string.utf8.count > maximumBytes else { return string }
    return String(decoding: string.utf8.prefix(maximumBytes), as: UTF8.self)
}
