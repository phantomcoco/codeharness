import CryptoKit
import Foundation

public struct WorkspaceInspector: WorkspaceInspecting {
    public init() {}
    public func inspect(workspace: Workspace) async throws -> WorkspaceInspection {
        HarnessTrace.log("workspace.inspect.start root=\(workspace.canonicalRootURL.path)")
        let root = workspace.canonicalRootURL
        let excludedNames: Set<String> = [".git", ".build", "DerivedData", "Pods", "node_modules", "xcuserdata"]
        var entries: [String] = []
        var previews: [String: String] = [:]
        var filesRead = 0
        var totalBytes = 0
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL, entries.count < 200 {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if excludedNames.contains(url.lastPathComponent) || rel.hasSuffix(".gguf") || rel.hasSuffix(".zip") || rel.hasSuffix(".dmg") {
                enumerator?.skipDescendants()
                continue
            }
            if rel.split(separator: "/").count > 4 {
                enumerator?.skipDescendants()
                continue
            }
            entries.append(rel)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == false, filesRead < 20, totalBytes < 500_000 {
                let bytes = min(values?.fileSize ?? 0, 100_000)
                if bytes > 0, let handle = try? FileHandle(forReadingFrom: url) {
                    let data = try handle.read(upToCount: bytes) ?? Data()
                    try? handle.close()
                    if let text = String(data: data, encoding: .utf8) {
                        previews[rel] = text
                        filesRead += 1
                        totalBytes += data.count
                    }
                }
            }
        }
        HarnessTrace.log("workspace.inspect.done entries=\(entries.count) previews=\(previews.count) bytes=\(totalBytes)")
        return WorkspaceInspection(entries: entries, filePreviews: previews)
    }
}
