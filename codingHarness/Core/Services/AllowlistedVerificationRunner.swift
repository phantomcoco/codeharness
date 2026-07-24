import CryptoKit
import Foundation

public actor AllowlistedVerificationRunner: VerificationRunning {
    public static let outputLimit = 50_000
    public static let timeoutSeconds: TimeInterval = 60
    private var process: Process?
    public init() {}

    public func run(commandID: String, workspace: Workspace) async throws -> VerificationResult {
        HarnessTrace.log("verify.run.start commandID=\(commandID) cwd=\(workspace.canonicalRootURL.path)")
        guard commandID == CommandPolicy.swiftTest.id else { throw AppFailure.commandNotAllowlisted(commandID) }
        let started = Date()
        let process = Process()
        self.process = process
        process.executableURL = CommandPolicy.swiftTest.executableURL
        process.arguments = CommandPolicy.swiftTest.arguments
        process.currentDirectoryURL = workspace.canonicalRootURL
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        while process.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled {
                process.terminate()
                timeoutTask.cancel()
                throw AppFailure.executionCancelled
            }
        }
        timeoutTask.cancel()
        self.process = nil
        let output = Self.bound(String(data: out.fileHandleForReading.readDataToEndOfFile() + err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        let duration = Date().timeIntervalSince(started)
        let timedOut = duration >= Self.timeoutSeconds && process.terminationStatus != 0
        if timedOut { throw AppFailure.commandTimedOut }
        HarnessTrace.log("verify.run.done commandID=\(commandID) exit=\(process.terminationStatus) duration=\(duration) outputChars=\(output.count)")
        return VerificationResult(commandID: commandID, exitCode: process.terminationStatus, output: output, duration: duration, timedOut: false, cancelled: false)
    }

    public func cancel() async {
        HarnessTrace.log("verify.cancel.request running=\(process != nil)")
        process?.terminate()
        process = nil
    }

    private static func bound(_ output: String) -> String {
        output.count > outputLimit ? String(output.prefix(outputLimit)) : output
    }
}
