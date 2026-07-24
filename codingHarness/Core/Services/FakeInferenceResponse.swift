import CryptoKit
import Foundation

public enum FakeInferenceResponse: Sendable {
    case success(String)
    case successFromRequest(@Sendable (InferenceRequest) -> String)
    case failure(AppFailure)
    case delayed(String)
}
