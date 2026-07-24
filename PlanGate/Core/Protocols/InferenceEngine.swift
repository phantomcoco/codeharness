import CryptoKit
import Foundation

public protocol InferenceEngine: Sendable {
    var state: InferenceState { get async }
    func loadModel(configuration: ModelConfiguration) async throws
    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error>
    func cancelGeneration() async
    func unloadModel() async
}
