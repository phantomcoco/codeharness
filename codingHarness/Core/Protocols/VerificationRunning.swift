import CryptoKit
import Foundation

public protocol VerificationRunning: Sendable {
    func run(commandID: String, workspace: Workspace) async throws -> VerificationResult
    func cancel() async
}
