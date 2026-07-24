import CryptoKit
import Foundation

public struct AppContainer {
    public let controller: CodingHarnessController
    public init(controller: CodingHarnessController) {
        self.controller = controller
    }
    public static func production() -> AppContainer {
        AppContainer(controller: CodingHarnessController(
            inference: LlamaInferenceEngine(),
            inspector: WorkspaceInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner()
        ))
    }

    public static func testing(inference: FakeInferenceEngine = FakeInferenceEngine()) -> AppContainer {
        AppContainer(controller: CodingHarnessController(
            inference: inference,
            inspector: WorkspaceInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner()
        ))
    }
}
