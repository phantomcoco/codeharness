import CryptoKit
import Foundation

public protocol FileWriting: Sendable {
    func write(content: String, relativePath: String, workspace: Workspace) async throws -> FileWriteResult
}
