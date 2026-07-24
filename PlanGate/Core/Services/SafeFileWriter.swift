import CryptoKit
import Foundation

public struct SafeFileWriter: FileWriting {
    public static let maxBytes = 1_048_576
    private let validator: WorkspaceSecurityValidator
    public init(validator: WorkspaceSecurityValidator = WorkspaceSecurityValidator()) {
        self.validator = validator
    }

    public func write(content: String, relativePath: String, workspace: Workspace) async throws -> FileWriteResult {
        PlanGateTrace.log("file.write.start path=\(relativePath) chars=\(content.count)")
        let data = Data(content.utf8)
        guard data.count <= Self.maxBytes else { throw AppFailure.writeFailed("payload exceeds 1 MB") }
        let target = try validator.resolve(relativePath: relativePath, in: workspace)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try validator.resolve(relativePath: relativePath, in: workspace)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            PlanGateTrace.log("file.write.done path=\(relativePath) bytes=\(data.count)")
            return FileWriteResult(relativePath: relativePath, resolvedPath: target.path, bytesWritten: data.count)
        } catch let error as AppFailure {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw AppFailure.writeFailed(error.localizedDescription)
        }
    }
}
