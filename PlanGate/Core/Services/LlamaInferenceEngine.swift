import CryptoKit
import Foundation

public actor LlamaInferenceEngine: @preconcurrency InferenceEngine {
    private let inner: NativeLlamaInferenceEngine
    public init() {
        inner = NativeLlamaInferenceEngine()
        PlanGateTrace.log("llama.wrapper.init native=true")
    }
    public var state: InferenceState { get async { await inner.state } }
    public func loadModel(configuration: ModelConfiguration) async throws { try await inner.loadModel(configuration: configuration) }
    public func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { inner.generate(request: request) }
    public func cancelGeneration() async { await inner.cancelGeneration() }
    public func unloadModel() async { await inner.unloadModel() }
}
