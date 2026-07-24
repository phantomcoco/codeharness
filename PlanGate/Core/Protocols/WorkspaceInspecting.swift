import CryptoKit
import Foundation

public protocol WorkspaceInspecting: Sendable {
    func inspect(workspace: Workspace) async throws -> WorkspaceInspection
}
