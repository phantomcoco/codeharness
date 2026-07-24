import CryptoKit
import Foundation

public struct WorkspaceSecurityValidator: Sendable {
    public init() {}

    public func canonicalWorkspace(from selected: URL) throws -> Workspace {
        let canonical = selected.standardizedFileURL.resolvingSymlinksInPath()
        HarnessTrace.log("workspace.canonicalize selected=\(selected.path) canonical=\(canonical.path)")
        return Workspace(selectedURL: selected, canonicalRootURL: canonical)
    }

    public func resolve(relativePath rawPath: String, in workspace: Workspace) throws -> URL {
        HarnessTrace.log("workspace.resolve.start path=\(rawPath) root=\(workspace.canonicalRootURL.path)")
        guard !rawPath.isEmpty else { throw AppFailure.invalidPath("empty") }
        guard rawPath.range(of: "\0") == nil else { throw AppFailure.invalidPath("null byte") }
        guard !rawPath.hasPrefix("/") else { throw AppFailure.absolutePathRejected }
        guard rawPath.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) == nil else { throw AppFailure.absolutePathRejected }
        guard !rawPath.hasPrefix("~") else { throw AppFailure.invalidPath("home expansion") }
        guard !rawPath.lowercased().hasPrefix("file://") else { throw AppFailure.invalidPath("file URL") }

        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains("..") else { throw AppFailure.traversalRejected }
        guard !parts.contains(".") else { throw AppFailure.invalidPath("dot segment") }

        let root = workspace.canonicalRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(rawPath).standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = resolvedParent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL
        guard isContained(resolved, in: root) else { throw AppFailure.targetOutsideWorkspace }
        if resolvedParent.path != candidate.deletingLastPathComponent().standardizedFileURL.path,
           !isContained(resolvedParent, in: root) {
            throw AppFailure.symlinkEscapeRejected
        }
        HarnessTrace.log("workspace.resolve.done path=\(rawPath) resolved=\(resolved.path)")
        return resolved
    }

    private func isContained(_ child: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count >= rootComponents.count &&
            Array(childComponents.prefix(rootComponents.count)) == rootComponents
    }
}
