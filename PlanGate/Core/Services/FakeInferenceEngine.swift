import CryptoKit
import Foundation

public actor FakeInferenceEngine: @preconcurrency InferenceEngine {
    public private(set) var loadCalls = 0
    public private(set) var generateCalls = 0
    private var responses: [FakeInferenceResponse]
    private var inferenceState: InferenceState = .unloaded
    private var cancelled = false
    public var state: InferenceState { inferenceState }

    public init(responses: [FakeInferenceResponse] = []) {
        self.responses = responses
    }

    public func enqueue(_ response: FakeInferenceResponse) {
        PlanGateTrace.log("fakeInference.enqueue")
        responses.append(response)
    }

    public func loadModel(configuration: ModelConfiguration) async throws {
        PlanGateTrace.log("fakeInference.loadModel file=\(configuration.url.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: configuration.canonicalPath) else {
            inferenceState = .failed("model file not found")
            throw AppFailure.modelLoadFailed("model file not found")
        }
        guard configuration.url.pathExtension.lowercased() == "gguf" else {
            inferenceState = .failed("unsupported model extension")
            throw AppFailure.modelLoadFailed("unsupported model extension")
        }
        loadCalls += 1
        inferenceState = .loaded(ModelMetadata(identifier: configuration.identifier, description: configuration.url.lastPathComponent))
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        PlanGateTrace.log("fakeInference.generate requestID=\(request.id) maxTokens=\(request.maxTokens)")
        generateCalls += 1
        cancelled = false
        let response = responses.isEmpty ? .failure(.planDecodingFailed("no fake response queued")) : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            Task {
                guard case .loaded = self.inferenceState else {
                    continuation.finish(throwing: AppFailure.modelNotLoaded)
                    return
                }
                continuation.yield(.started)
                switch response {
                case .success(let text):
                    continuation.yield(.promptEvaluated)
                    continuation.yield(.token(text))
                    continuation.yield(.completed(text))
                    continuation.finish()
                case .successFromRequest(let makeText):
                    let text = makeText(request)
                    continuation.yield(.promptEvaluated)
                    continuation.yield(.token(text))
                    continuation.yield(.completed(text))
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .delayed(let text):
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.cancelled {
                        continuation.yield(.cancelled)
                        continuation.finish(throwing: AppFailure.generationCancelled)
                    } else {
                        continuation.yield(.promptEvaluated)
                        continuation.yield(.token(text))
                        continuation.yield(.completed(text))
                        continuation.finish()
                    }
                }
            }
        }
    }

    public func cancelGeneration() async {
        PlanGateTrace.log("fakeInference.cancelGeneration")
        cancelled = true
    }

    public func unloadModel() async {
        PlanGateTrace.log("fakeInference.unloadModel")
        inferenceState = .unloaded
    }
}
