import CryptoKit
import Foundation

public struct AppContainer {
    public let controller: PlanGateController
    public init(controller: PlanGateController) {
        self.controller = controller
    }
    public static func production() -> AppContainer {
        AppContainer(controller: PlanGateController(
            inference: LlamaInferenceEngine(),
            inspector: WorkspaceInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner()
        ))
    }

    public static func testing(inference: FakeInferenceEngine = FakeInferenceEngine()) -> AppContainer {
        AppContainer(controller: PlanGateController(
            inference: inference,
            inspector: WorkspaceInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner()
        ))
    }
}
