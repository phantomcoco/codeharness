// Domain models for the Local AI Coding Harness.
//
// These value types were previously defined in Core/HarnessCore.swift. When the
// harness was split into per-responsibility files (commit 4fb596f), the service
// and protocol types were extracted but this shared domain layer was omitted,
// which broke the build. Restored verbatim from the pre-split definitions (2094070).

import Foundation

public enum HarnessState: Equatable, Sendable, CustomStringConvertible {
    case idle
    case planning
    case awaitingApproval
    case executing
    case completed(ExecutionSummary)
    case failed(AppFailure)
    case cancelled

    public var description: String {
        switch self {
        case .idle:
            "idle"
        case .planning:
            "planning"
        case .awaitingApproval:
            "awaiting approval"
        case .executing:
            "executing"
        case .completed(let summary):
            "completed: \(summary.message)"
        case .failed(let failure):
            failure.description
        case .cancelled:
            "cancelled"
        }
    }
}

public enum AppFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidStateTransition(String)
    case workspaceNotSelected
    case modelNotSelected
    case modelNotLoaded
    case taskIsEmpty
    case planDecodingFailed(String)
    case unsupportedProtocolVersion(Int)
    case wrongMessageForState(String)
    case planNotApproved
    case approvalMismatch
    case actionNotInApprovedPlan(String)
    case tooManyWriteActions
    case tooManyVerificationActions
    case unsupportedAction(String)
    case absolutePathRejected
    case traversalRejected
    case symlinkEscapeRejected
    case targetOutsideWorkspace
    case invalidPath(String)
    case writeFailed(String)
    case commandNotAllowlisted(String)
    case commandTimedOut
    case commandFailed(Int32)
    case generationCancelled
    case executionCancelled
    case modelLoadFailed(String)

    public var description: String {
        switch self {
        case .invalidStateTransition(let message): "Invalid state transition: \(message)"
        case .workspaceNotSelected: "Select a workspace first."
        case .modelNotSelected: "Select a GGUF model first."
        case .modelNotLoaded: "Load the selected model before planning."
        case .taskIsEmpty: "Enter a coding task first."
        case .planDecodingFailed(let message): "Plan JSON could not be decoded: \(message)"
        case .unsupportedProtocolVersion(let version): "Unsupported protocol version \(version)."
        case .wrongMessageForState(let message): "Wrong model message for current state: \(message)"
        case .planNotApproved: "Current plan is not approved."
        case .approvalMismatch: "Approval no longer matches the displayed plan."
        case .actionNotInApprovedPlan(let id): "Action \(id) is not in the approved plan."
        case .tooManyWriteActions: "Plan contains more than two write actions."
        case .tooManyVerificationActions: "Plan contains more than one verification action."
        case .unsupportedAction(let kind): "Unsupported action kind: \(kind)."
        case .absolutePathRejected: "Absolute paths are not allowed."
        case .traversalRejected: "Parent-directory traversal is not allowed."
        case .symlinkEscapeRejected: "Path resolves through a symlink outside the workspace."
        case .targetOutsideWorkspace: "Target is outside the selected workspace."
        case .invalidPath(let message): "Invalid path: \(message)"
        case .writeFailed(let message): "Write failed: \(message)"
        case .commandNotAllowlisted(let command): "Rejected unsafe command: \(command)"
        case .commandTimedOut: "Verification timed out."
        case .commandFailed(let code): "Verification failed with exit code \(code)."
        case .generationCancelled: "Generation cancelled."
        case .executionCancelled: "Execution cancelled."
        case .modelLoadFailed(let message): "Model load failed: \(message)"
        }
    }
}

public enum LlamaInferenceError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case invalidModelURL
    case modelFileMissing
    case unsupportedModel
    case backendInitializationFailed
    case modelLoadFailed
    case contextCreationFailed
    case modelNotLoaded
    case generationAlreadyRunning
    case promptTooLarge(promptTokens: Int, contextSize: UInt32)
    case tokenizationFailed
    case promptDecodeFailed
    case tokenDecodeFailed
    case chatTemplateUnavailable
    case chatTemplateFormattingFailed
    case cancelled

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidModelURL: "Invalid model URL."
        case .modelFileMissing: "Model file is missing."
        case .unsupportedModel: "Unsupported model file. Select a readable .gguf file."
        case .backendInitializationFailed: "llama.cpp backend initialization failed."
        case .modelLoadFailed: "llama.cpp failed to load the model."
        case .contextCreationFailed: "llama.cpp failed to create a context."
        case .modelNotLoaded: "Model is not loaded."
        case .generationAlreadyRunning: "Generation is already running."
        case .promptTooLarge(let promptTokens, let contextSize): "Prompt is too large: \(promptTokens) tokens for context \(contextSize)."
        case .tokenizationFailed: "llama.cpp tokenization failed."
        case .promptDecodeFailed: "llama.cpp prompt decode failed."
        case .tokenDecodeFailed: "llama.cpp token decode failed."
        case .chatTemplateUnavailable: "Model chat template is unavailable."
        case .chatTemplateFormattingFailed: "llama.cpp chat-template formatting failed."
        case .cancelled: "Generation cancelled."
        }
    }
}

public struct Workspace: Equatable, Sendable {
    public let selectedURL: URL
    public let canonicalRootURL: URL
    public init(selectedURL: URL, canonicalRootURL: URL) {
        self.selectedURL = selectedURL
        self.canonicalRootURL = canonicalRootURL
    }
}

public struct ModelConfiguration: Equatable, Sendable {
    public let url: URL
    public let canonicalPath: String
    public let fileSizeBytes: Int64
    public let contextSize: UInt32
    public let maximumOutputTokens: Int
    public let threadCount: Int32
    public let batchThreadCount: Int32
    public let gpuLayerCount: Int32
    public let temperature: Float
    public let seed: UInt32
    public var identifier: String { "\(url.lastPathComponent)|\(fileSizeBytes)|\(canonicalPath)" }

    public init(
        url: URL,
        canonicalPath: String,
        fileSizeBytes: Int64,
        contextSize: UInt32 = 4096,
        maximumOutputTokens: Int = 1024,
        threadCount: Int32 = ModelConfiguration.defaultThreadCount(),
        batchThreadCount: Int32 = ModelConfiguration.defaultThreadCount(),
        gpuLayerCount: Int32 = ModelConfiguration.defaultGPULayerCount(),
        temperature: Float = 0.2,
        seed: UInt32 = 1234
    ) {
        self.url = url
        self.canonicalPath = canonicalPath
        self.fileSizeBytes = fileSizeBytes
        self.contextSize = contextSize
        self.maximumOutputTokens = maximumOutputTokens
        self.threadCount = threadCount
        self.batchThreadCount = batchThreadCount
        self.gpuLayerCount = gpuLayerCount
        self.temperature = temperature
        self.seed = seed
    }

    public static func defaultThreadCount() -> Int32 {
        Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    public static func defaultGPULayerCount() -> Int32 {
        #if arch(arm64)
        return 999
        #else
        return 0
        #endif
    }
}

public struct ModelMetadata: Codable, Equatable, Sendable {
    public let identifier: String
    public let description: String
    public let contextSize: UInt32
    public let threadCount: Int32
    public let batchThreadCount: Int32
    public let gpuLayerCount: Int32
    public let backendDescription: String
    public let loadDuration: TimeInterval
    public let sizeBytes: UInt64
    public let parameterCount: UInt64

    public init(
        identifier: String,
        description: String,
        contextSize: UInt32 = 0,
        threadCount: Int32 = 0,
        batchThreadCount: Int32 = 0,
        gpuLayerCount: Int32 = 0,
        backendDescription: String = "unknown",
        loadDuration: TimeInterval = 0,
        sizeBytes: UInt64 = 0,
        parameterCount: UInt64 = 0
    ) {
        self.identifier = identifier
        self.description = description
        self.contextSize = contextSize
        self.threadCount = threadCount
        self.batchThreadCount = batchThreadCount
        self.gpuLayerCount = gpuLayerCount
        self.backendDescription = backendDescription
        self.loadDuration = loadDuration
        self.sizeBytes = sizeBytes
        self.parameterCount = parameterCount
    }
}

public enum InferenceState: Equatable, Sendable {
    case unloaded
    case loading
    case loaded(ModelMetadata)
    case generating
    case failed(String)
}

public struct BehaviorGuidance: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case none
        case file(URL)
        case manual
    }
    public let source: Source
    public let content: String
    public static let none = BehaviorGuidance(source: .none, content: "")
    public init(source: Source, content: String) {
        self.source = source
        self.content = content
    }
    public var digest: String { SHA256Digest.hash(content) }
    public var preview: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).description
    }
}

public struct CodingTask: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

public enum PlannedActionKind: String, Sendable {
    case writeFile
    case verify
}

extension PlannedActionKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "writefile", "write_file", "write-file", "write":
            self = .writeFile
        case "verify", "test", "run_tests", "run-tests", "swift-test":
            self = .verify
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize PlannedActionKind from invalid String value \(rawValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PlannedAction: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: PlannedActionKind
    public let relativePath: String?
    public let commandID: String?
    public let description: String
    public init(id: String, kind: PlannedActionKind, relativePath: String? = nil, commandID: String? = nil, description: String) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.commandID = commandID
        self.description = description
    }
}

public struct ProposedPlan: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let taskText: String
    public let workspaceCanonicalPath: String
    public let modelIdentifier: String
    public let guidanceDigest: String
    public let summary: String
    public let actions: [PlannedAction]
    public let createdAt: Date
    public init(id: UUID = UUID(), taskID: UUID, taskText: String, workspaceCanonicalPath: String, modelIdentifier: String, guidanceDigest: String, summary: String, actions: [PlannedAction], createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.taskText = taskText
        self.workspaceCanonicalPath = workspaceCanonicalPath
        self.modelIdentifier = modelIdentifier
        self.guidanceDigest = guidanceDigest
        self.summary = summary
        self.actions = actions
        self.createdAt = createdAt
    }
}

public struct ApprovalRecord: Equatable, Sendable {
    public let planID: UUID
    public let fingerprint: String
    public let approvedAt: Date
}

public struct ActivityEvent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case state, model, inspection, approval, validation, fileWrite, verification, cancellation, error
    }
    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let message: String
    public init(id: UUID = UUID(), date: Date, kind: Kind, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
    }
}

public struct FileWriteResult: Equatable, Sendable {
    public let relativePath: String
    public let resolvedPath: String
    public let bytesWritten: Int
}

public struct VerificationResult: Equatable, Sendable {
    public let commandID: String
    public let exitCode: Int32
    public let output: String
    public let duration: TimeInterval
    public let timedOut: Bool
    public let cancelled: Bool
}

public struct ExecutionSummary: Equatable, Sendable {
    public let modifiedFile: FileWriteResult?
    public let verification: VerificationResult?
    public let message: String
}

public enum ModelMessageType: String, Codable, Sendable {
    case plan, act, finish, stop
}

public struct ModelEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let type: ModelMessageType
    public let requestID: UUID
    public let payload: Payload
}

public struct PlanPayload: Codable, Equatable, Sendable {
    public let summary: String
    public let actions: [PlannedAction]
}

public struct ActPayload: Codable, Equatable, Sendable {
    public let planID: UUID
    public let actionID: String
    public let action: ExecutableAction
}

public struct FinishPayload: Codable, Equatable, Sendable {
    public let planID: UUID
    public let summary: String
}

public struct StopPayload: Codable, Equatable, Sendable {
    public let reason: String
}

public enum ExecutableAction: Codable, Equatable, Sendable {
    case writeFile(relativePath: String, content: String)
    case verify(commandID: String)

    private enum CodingKeys: String, CodingKey { case kind, relativePath, content, commandID }
    private enum Kind: String, Codable { case writeFile, verify }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .writeFile:
            self = .writeFile(
                relativePath: try container.decode(String.self, forKey: .relativePath),
                content: try container.decode(String.self, forKey: .content)
            )
        case .verify:
            self = .verify(commandID: try container.decode(String.self, forKey: .commandID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .writeFile(let path, let content):
            try container.encode(Kind.writeFile, forKey: .kind)
            try container.encode(path, forKey: .relativePath)
            try container.encode(content, forKey: .content)
        case .verify(let commandID):
            try container.encode(Kind.verify, forKey: .kind)
            try container.encode(commandID, forKey: .commandID)
        }
    }
}

public struct InferenceRequest: Equatable, Sendable {
    public let id: UUID
    public let prompt: String
    public let messages: [InferenceMessage]
    public let maxTokens: Int
    public init(id: UUID = UUID(), prompt: String, maxTokens: Int = 1024) {
        self.id = id
        self.prompt = prompt
        self.messages = [InferenceMessage(role: .user, content: prompt)]
        self.maxTokens = maxTokens
    }

    public init(id: UUID = UUID(), messages: [InferenceMessage], maxTokens: Int = 1024) {
        self.id = id
        self.messages = messages
        self.prompt = messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        self.maxTokens = maxTokens
    }
}

public enum InferenceEvent: Equatable, Sendable {
    case started
    case promptEvaluated
    case token(String)
    case completed(String)
    case cancelled
}

public struct InferenceMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct NativeSmokeTestResult: Equatable, Sendable {
    public let rawOutput: String
    public let loadDuration: TimeInterval
    public let promptEvaluationDuration: TimeInterval
    public let generationDuration: TimeInterval
    public let generatedTokenCount: Int
    public let tokensPerSecond: Double
    public let completed: Bool
}

public struct WorkspaceInspection: Equatable, Sendable {
    public let entries: [String]
    public let filePreviews: [String: String]
    public init(entries: [String], filePreviews: [String: String]) {
        self.entries = entries
        self.filePreviews = filePreviews
    }
}
