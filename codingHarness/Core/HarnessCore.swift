import CryptoKit
import Foundation

public enum HarnessTrace {
    #if DEBUG
    public static var isEnabled = true

    public static func log(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard isEnabled else { return }
        print("[HarnessTrace] \(file):\(line) \(message())")
    }
    #else
    public static var isEnabled = false

    public static func log(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {}
    #endif
}

public enum HarnessState: Equatable, Sendable {
    case idle
    case planning
    case awaitingApproval
    case executing
    case completed(ExecutionSummary)
    case failed(AppFailure)
    case cancelled
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
        case .tooManyWriteActions: "Plan contains more than one write action."
        case .tooManyVerificationActions: "Plan contains more than one verification action."
        case .unsupportedAction(let kind): "Unsupported action kind: \(kind)."
        case .absolutePathRejected: "Absolute paths are not allowed."
        case .traversalRejected: "Parent-directory traversal is not allowed."
        case .symlinkEscapeRejected: "Path resolves through a symlink outside the workspace."
        case .targetOutsideWorkspace: "Target is outside the selected workspace."
        case .invalidPath(let message): "Invalid path: \(message)"
        case .writeFailed(let message): "Write failed: \(message)"
        case .commandNotAllowlisted(let command): "Command is not allowlisted: \(command)"
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

public enum PlannedActionKind: String, Codable, Sendable {
    case writeFile
    case verify
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

public protocol InferenceEngine: Sendable {
    var state: InferenceState { get async }
    func loadModel(configuration: ModelConfiguration) async throws
    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error>
    func cancelGeneration() async
    func unloadModel() async
}

public protocol WorkspaceInspecting: Sendable {
    func inspect(workspace: Workspace) async throws -> WorkspaceInspection
}

public protocol FileWriting: Sendable {
    func write(content: String, relativePath: String, workspace: Workspace) async throws -> FileWriteResult
}

public protocol VerificationRunning: Sendable {
    func run(commandID: String, workspace: Workspace) async throws -> VerificationResult
    func cancel() async
}

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct FixedClock: Clock {
    public let fixedDate: Date
    public init(_ fixedDate: Date) { self.fixedDate = fixedDate }
    public func now() -> Date { fixedDate }
}

public struct WorkspaceInspection: Equatable, Sendable {
    public let entries: [String]
    public let filePreviews: [String: String]
    public init(entries: [String], filePreviews: [String: String]) {
        self.entries = entries
        self.filePreviews = filePreviews
    }
}

public final class HarnessStateMachine: Sendable {
    public init() {}
    public func transition(from current: HarnessState, to next: HarnessState, hasApprovedPlan: Bool = false) throws -> HarnessState {
        HarnessTrace.log("state.transition.request current=\(current) next=\(next) hasApprovedPlan=\(hasApprovedPlan)")
        switch (current, next) {
        case (.idle, .planning),
             (.planning, .awaitingApproval),
             (.planning, .failed),
             (.planning, .cancelled),
             (.awaitingApproval, .idle),
             (.awaitingApproval, .failed),
             (.awaitingApproval, .cancelled),
             (.executing, .completed),
             (.executing, .failed),
             (.executing, .cancelled),
             (.completed, .idle),
             (.failed, .idle),
             (.cancelled, .idle):
            HarnessTrace.log("state.transition.allowed current=\(current) next=\(next)")
            return next
        case (.awaitingApproval, .executing) where hasApprovedPlan:
            HarnessTrace.log("state.transition.allowed current=\(current) next=\(next)")
            return next
        default:
            HarnessTrace.log("state.transition.rejected current=\(current) next=\(next)")
            throw AppFailure.invalidStateTransition("\(current) -> \(next)")
        }
    }
}

public enum SHA256Digest {
    public static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ApprovalBindingService: Sendable {
    public init() {}

    public func fingerprint(plan: ProposedPlan) throws -> String {
        HarnessTrace.log("approval.fingerprint.start planID=\(plan.id) actions=\(plan.actions.count)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let fingerprint = SHA256Digest.hash(data: try encoder.encode(plan))
        HarnessTrace.log("approval.fingerprint.done planID=\(plan.id) prefix=\(fingerprint.prefix(12))")
        return fingerprint
    }

    public func approve(plan: ProposedPlan, at date: Date) throws -> ApprovalRecord {
        HarnessTrace.log("approval.approve.start planID=\(plan.id)")
        return ApprovalRecord(planID: plan.id, fingerprint: try fingerprint(plan: plan), approvedAt: date)
    }

    public func validate(record: ApprovalRecord?, plan: ProposedPlan?) throws {
        HarnessTrace.log("approval.validate.start recordPresent=\(record != nil) planPresent=\(plan != nil)")
        guard let record, let plan else { throw AppFailure.planNotApproved }
        guard record.planID == plan.id else { throw AppFailure.approvalMismatch }
        guard try record.fingerprint == fingerprint(plan: plan) else { throw AppFailure.approvalMismatch }
        HarnessTrace.log("approval.validate.done planID=\(plan.id)")
    }
}

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

public struct PlanValidator: Sendable {
    public static let maxActions = 2
    private let security: WorkspaceSecurityValidator
    public init(security: WorkspaceSecurityValidator = WorkspaceSecurityValidator()) {
        self.security = security
    }

    public func validate(plan: ProposedPlan, workspace: Workspace) throws {
        HarnessTrace.log("plan.validate.start planID=\(plan.id) actions=\(plan.actions.count)")
        guard plan.actions.count <= Self.maxActions else { throw AppFailure.unsupportedAction("too many actions") }
        let writes = plan.actions.filter { $0.kind == .writeFile }
        let verifies = plan.actions.filter { $0.kind == .verify }
        guard writes.count <= 1 else { throw AppFailure.tooManyWriteActions }
        guard verifies.count <= 1 else { throw AppFailure.tooManyVerificationActions }
        if let write = writes.first {
            guard let path = write.relativePath else { throw AppFailure.invalidPath("missing relativePath") }
            _ = try security.resolve(relativePath: path, in: workspace)
        }
        if let verify = verifies.first {
            guard verify.commandID == CommandPolicy.swiftTest.id else {
                throw AppFailure.commandNotAllowlisted(verify.commandID ?? "")
            }
        }
        if writes.first != nil, verifies.first != nil {
            guard plan.actions.first?.kind == .writeFile, plan.actions.last?.kind == .verify else {
                throw AppFailure.unsupportedAction("write must precede verify")
            }
        }
        HarnessTrace.log("plan.validate.done planID=\(plan.id) writes=\(writes.count) verifies=\(verifies.count)")
    }
}

public struct StructuredMessageDecoder: Sendable {
    public init() {}

    public func jsonEnvelopeData(from text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let json = Self.firstBalancedJSONObject(in: trimmed),
              let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AppFailure.planDecodingFailed("No valid JSON object found in model output.")
        }
        return data
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    public func decodeEnvelopeHeader(_ data: Data) throws -> ModelMessageType {
        HarnessTrace.log("message.decodeHeader.start bytes=\(data.count)")
        struct Header: Decodable { let protocolVersion: Int; let type: ModelMessageType }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.protocolVersion == 1 else { throw AppFailure.unsupportedProtocolVersion(header.protocolVersion) }
            HarnessTrace.log("message.decodeHeader.done type=\(header.type)")
            return header.type
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.planDecodingFailed(error.localizedDescription)
        }
    }

    public func decodePlan(_ text: String, requestID: UUID, task: CodingTask, workspace: Workspace, model: ModelConfiguration, guidance: BehaviorGuidance, date: Date) throws -> ProposedPlan {
        HarnessTrace.log("message.decodePlan.start requestID=\(requestID) chars=\(text.count)")
        let data = try jsonEnvelopeData(from: text)
        guard try decodeEnvelopeHeader(data) == .plan else { throw AppFailure.wrongMessageForState("expected plan") }
        do {
            let envelope = try JSONDecoder().decode(ModelEnvelope<PlanPayload>.self, from: data)
            guard envelope.requestID == requestID else { throw AppFailure.wrongMessageForState("request id mismatch") }
            let plan = ProposedPlan(
                taskID: task.id,
                taskText: task.text,
                workspaceCanonicalPath: workspace.canonicalRootURL.path,
                modelIdentifier: model.identifier,
                guidanceDigest: guidance.digest,
                summary: envelope.payload.summary,
                actions: envelope.payload.actions,
                createdAt: date
            )
            HarnessTrace.log("message.decodePlan.done requestID=\(requestID) actions=\(plan.actions.count)")
            return plan
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.planDecodingFailed(error.localizedDescription)
        }
    }

    public func decodeAct(_ text: String, requestID: UUID) throws -> ActPayload {
        HarnessTrace.log("message.decodeAct.start requestID=\(requestID) chars=\(text.count)")
        let data = try jsonEnvelopeData(from: text)
        guard try decodeEnvelopeHeader(data) == .act else { throw AppFailure.wrongMessageForState("expected act") }
        let envelope = try JSONDecoder().decode(ModelEnvelope<ActPayload>.self, from: data)
        guard envelope.requestID == requestID else { throw AppFailure.wrongMessageForState("request id mismatch") }
        HarnessTrace.log("message.decodeAct.done requestID=\(requestID) actionID=\(envelope.payload.actionID)")
        return envelope.payload
    }
}

public struct CommandPolicy: Equatable, Sendable {
    public let id: String
    public let executableURL: URL
    public let arguments: [String]
    public static let swiftTest = CommandPolicy(
        id: "swift-test",
        executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
        arguments: ["test"]
    )
}

public struct SafeFileWriter: FileWriting {
    public static let maxBytes = 1_048_576
    private let validator: WorkspaceSecurityValidator
    public init(validator: WorkspaceSecurityValidator = WorkspaceSecurityValidator()) {
        self.validator = validator
    }

    public func write(content: String, relativePath: String, workspace: Workspace) async throws -> FileWriteResult {
        HarnessTrace.log("file.write.start path=\(relativePath) chars=\(content.count)")
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
            HarnessTrace.log("file.write.done path=\(relativePath) bytes=\(data.count)")
            return FileWriteResult(relativePath: relativePath, resolvedPath: target.path, bytesWritten: data.count)
        } catch let error as AppFailure {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw AppFailure.writeFailed(error.localizedDescription)
        }
    }
}

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

public enum FakeInferenceResponse: Sendable {
    case success(String)
    case failure(AppFailure)
    case delayed(String)
}

public actor FakeInferenceEngine: @preconcurrency InferenceEngine {
    public private(set) var loadCalls = 0
    public private(set) var generateCalls = 0
    private var responses: [FakeInferenceResponse]
    private var inferenceState: InferenceState = .unloaded
    private var cancelled = false
    public var state: InferenceState { inferenceState }

    public init(responses: [FakeInferenceResponse] = []) {
        self.responses = responses
    }

    public func enqueue(_ response: FakeInferenceResponse) {
        HarnessTrace.log("fakeInference.enqueue")
        responses.append(response)
    }

    public func loadModel(configuration: ModelConfiguration) async throws {
        HarnessTrace.log("fakeInference.loadModel file=\(configuration.url.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: configuration.canonicalPath) else {
            inferenceState = .failed("model file not found")
            throw AppFailure.modelLoadFailed("model file not found")
        }
        guard configuration.url.pathExtension.lowercased() == "gguf" else {
            inferenceState = .failed("unsupported model extension")
            throw AppFailure.modelLoadFailed("unsupported model extension")
        }
        loadCalls += 1
        inferenceState = .loaded(ModelMetadata(identifier: configuration.identifier, description: configuration.url.lastPathComponent))
    }

    public func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        HarnessTrace.log("fakeInference.generate requestID=\(request.id) maxTokens=\(request.maxTokens)")
        generateCalls += 1
        cancelled = false
        let response = responses.isEmpty ? .failure(.planDecodingFailed("no fake response queued")) : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            Task {
                guard case .loaded = self.inferenceState else {
                    continuation.finish(throwing: AppFailure.modelNotLoaded)
                    return
                }
                continuation.yield(.started)
                switch response {
                case .success(let text):
                    continuation.yield(.promptEvaluated)
                    continuation.yield(.token(text))
                    continuation.yield(.completed(text))
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .delayed(let text):
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.cancelled {
                        continuation.yield(.cancelled)
                        continuation.finish(throwing: AppFailure.generationCancelled)
                    } else {
                        continuation.yield(.promptEvaluated)
                        continuation.yield(.token(text))
                        continuation.yield(.completed(text))
                        continuation.finish()
                    }
                }
            }
        }
    }

    public func cancelGeneration() async {
        HarnessTrace.log("fakeInference.cancelGeneration")
        cancelled = true
    }

    public func unloadModel() async {
        HarnessTrace.log("fakeInference.unloadModel")
        inferenceState = .unloaded
    }
}

public actor LlamaInferenceEngine: @preconcurrency InferenceEngine {
    private let inner: NativeLlamaInferenceEngine
    public init() {
        inner = NativeLlamaInferenceEngine()
        HarnessTrace.log("llama.wrapper.init native=true")
    }
    public var state: InferenceState { get async { await inner.state } }
    public func loadModel(configuration: ModelConfiguration) async throws { try await inner.loadModel(configuration: configuration) }
    public func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { inner.generate(request: request) }
    public func cancelGeneration() async { await inner.cancelGeneration() }
    public func unloadModel() async { await inner.unloadModel() }
}

public actor CodingHarnessController {
    public private(set) var state: HarnessState = .idle
    public private(set) var workspace: Workspace?
    public private(set) var model: ModelConfiguration?
    public private(set) var guidance: BehaviorGuidance = .none
    public private(set) var task: CodingTask?
    public private(set) var proposedPlan: ProposedPlan?
    public private(set) var approval: ApprovalRecord?
    public private(set) var events: [ActivityEvent] = []

    private let inference: any InferenceEngine
    private let inspector: any WorkspaceInspecting
    private let fileWriter: any FileWriting
    private let verifier: any VerificationRunning
    private let approvals: ApprovalBindingService
    private let stateMachine: HarnessStateMachine
    private let clock: any Clock
    private let planValidator: PlanValidator
    private let decoder = StructuredMessageDecoder()
    private var activeTask: Task<Void, Never>?

    public init(
        inference: any InferenceEngine,
        inspector: any WorkspaceInspecting,
        fileWriter: any FileWriting,
        verifier: any VerificationRunning,
        approvals: ApprovalBindingService = ApprovalBindingService(),
        stateMachine: HarnessStateMachine = HarnessStateMachine(),
        clock: any Clock = SystemClock(),
        planValidator: PlanValidator = PlanValidator()
    ) {
        self.inference = inference
        self.inspector = inspector
        self.fileWriter = fileWriter
        self.verifier = verifier
        self.approvals = approvals
        self.stateMachine = stateMachine
        self.clock = clock
        self.planValidator = planValidator
    }

    public func selectWorkspace(_ workspace: Workspace) async {
        HarnessTrace.log("controller.selectWorkspace.start path=\(workspace.canonicalRootURL.path)")
        await cancelCurrentOperation()
        self.workspace = workspace
        invalidateApprovalAndPlan("Workspace changed; approval invalidated.")
        state = .idle
        log(.validation, "Workspace selected: \(workspace.canonicalRootURL.path)")
        HarnessTrace.log("controller.selectWorkspace.done state=\(state)")
    }

    public func selectModel(_ model: ModelConfiguration) async {
        HarnessTrace.log("controller.selectModel.start file=\(model.url.lastPathComponent)")
        await cancelCurrentOperation()
        self.model = model
        invalidateApprovalAndPlan("Model changed; approval invalidated.")
        state = .idle
        log(.model, "Model selected: \(model.url.lastPathComponent)")
        HarnessTrace.log("controller.selectModel.done state=\(state)")
    }

    public func setGuidance(_ guidance: BehaviorGuidance) async {
        HarnessTrace.log("controller.setGuidance.start source=\(guidance.source) chars=\(guidance.content.count)")
        await cancelCurrentOperation()
        self.guidance = guidance
        invalidateApprovalAndPlan("Behavior guidance changed; approval invalidated.")
        state = .idle
        HarnessTrace.log("controller.setGuidance.done state=\(state)")
    }

    public func setTaskText(_ text: String) async {
        HarnessTrace.log("controller.setTaskText chars=\(text.count)")
        task = CodingTask(text: text)
        invalidateApprovalAndPlan("Task changed; approval invalidated.")
    }

    public func loadModel() async throws {
        HarnessTrace.log("controller.loadModel.start")
        guard let model else { throw record(.modelNotSelected) }
        try await inference.loadModel(configuration: model)
        log(.model, "Model loaded.")
        let loadedState = await inference.state
        HarnessTrace.log("controller.loadModel.done inferenceState=\(loadedState)")
    }

    public func unloadModel() async {
        HarnessTrace.log("controller.unloadModel.start")
        await inference.unloadModel()
        approval = nil
        log(.model, "Model unloaded; approval invalidated.")
        HarnessTrace.log("controller.unloadModel.done")
    }

    public func generatePlan() async {
        HarnessTrace.log("controller.generatePlan.start state=\(state)")
        do {
            guard let workspace else { throw AppFailure.workspaceNotSelected }
            guard let model else { throw AppFailure.modelNotSelected }
            guard let task, !task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure.taskIsEmpty }
            guard case .loaded = await inference.state else { throw AppFailure.modelNotLoaded }
            try changeState(.planning)
            let requestID = UUID()
            HarnessTrace.log("controller.generatePlan.requestID=\(requestID)")
            log(.inspection, "Inspecting workspace with bounded read-only policy.")
            let inspection = try await inspector.inspect(workspace: workspace)
            HarnessTrace.log("controller.generatePlan.inspection entries=\(inspection.entries.count) previews=\(inspection.filePreviews.count)")
            let messages = LlamaPromptBuilder.planningMessages(requestID: requestID, task: task, guidance: guidance, inspection: inspection)
            HarnessTrace.log("controller.generatePlan.prompt chars=\(messages.reduce(0) { $0 + $1.content.count })")
            var output = ""
            for try await event in inference.generate(request: InferenceRequest(id: requestID, messages: messages, maxTokens: model.maximumOutputTokens)) {
                switch event {
                case .token(let text):
                    output += text
                case .cancelled:
                    throw AppFailure.generationCancelled
                default:
                    break
                }
            }
            HarnessTrace.log("controller.generatePlan.modelOutput chars=\(output.count)")
            let plan = try decoder.decodePlan(output, requestID: requestID, task: task, workspace: workspace, model: model, guidance: guidance, date: clock.now())
            try planValidator.validate(plan: plan, workspace: workspace)
            proposedPlan = plan
            approval = nil
            try changeState(.awaitingApproval)
            log(.validation, "Plan validated with \(plan.actions.count) action(s).")
            HarnessTrace.log("controller.generatePlan.done planID=\(plan.id) actions=\(plan.actions.count)")
        } catch {
            HarnessTrace.log("controller.generatePlan.failed error=\(error)")
            await fail(error)
        }
    }

    public func runNativeSmokeTest() async throws -> NativeSmokeTestResult {
        HarnessTrace.log("controller.smoke.start")
        guard let model else { throw record(.modelNotSelected) }
        guard case .loaded(let metadata) = await inference.state else { throw record(.modelNotLoaded) }
        let requestID = UUID()
        let messages = [
            InferenceMessage(role: .system, content: "Return only valid JSON. No Markdown. No prose."),
            InferenceMessage(role: .user, content: #"Return exactly this JSON: {"type":"stop","reason":"native inference is working"}"#)
        ]
        let started = Date()
        var promptEvaluatedAt: Date?
        var output = ""
        var tokenCount = 0
        for try await event in inference.generate(request: InferenceRequest(id: requestID, messages: messages, maxTokens: min(128, model.maximumOutputTokens))) {
            switch event {
            case .promptEvaluated:
                promptEvaluatedAt = Date()
            case .token(let text):
                tokenCount += 1
                output += text
            case .cancelled:
                throw AppFailure.generationCancelled
            default:
                break
            }
        }
        let ended = Date()
        let promptDuration = (promptEvaluatedAt ?? ended).timeIntervalSince(started)
        let generationDuration = ended.timeIntervalSince(promptEvaluatedAt ?? started)
        let completed = Self.acceptsSmokeOutput(output)
        let tps = generationDuration > 0 ? Double(tokenCount) / generationDuration : 0
        let result = NativeSmokeTestResult(
            rawOutput: output,
            loadDuration: metadata.loadDuration,
            promptEvaluationDuration: promptDuration,
            generationDuration: generationDuration,
            generatedTokenCount: tokenCount,
            tokensPerSecond: tps,
            completed: completed
        )
        log(.model, completed ? "Native smoke test produced expected JSON." : "Native smoke test completed but output did not match expected JSON.")
        HarnessTrace.log("controller.smoke.done completed=\(completed) tokens=\(tokenCount)")
        return result
    }

    private static func acceptsSmokeOutput(_ output: String) -> Bool {
        guard let data = smokeJSONCandidate(from: output).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 2,
              object["type"] as? String == "stop",
              object["reason"] as? String == "native inference is working" else {
            return false
        }
        return true
    }

    private static func smokeJSONCandidate(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    public func approvePlan() throws {
        HarnessTrace.log("controller.approvePlan.start state=\(state)")
        guard case .awaitingApproval = state else { throw record(.invalidStateTransition("approval allowed only while awaiting approval")) }
        guard let proposedPlan else { throw record(.planNotApproved) }
        approval = try approvals.approve(plan: proposedPlan, at: clock.now())
        log(.approval, "Plan approved. Fingerprint \(approval?.fingerprint.prefix(12) ?? "").")
        HarnessTrace.log("controller.approvePlan.done planID=\(proposedPlan.id)")
    }

    public func rejectPlan() async {
        HarnessTrace.log("controller.rejectPlan.start")
        approval = nil
        log(.approval, "Plan rejected; execution disabled.")
        do { try changeState(.idle) } catch { await fail(error) }
        HarnessTrace.log("controller.rejectPlan.done state=\(state)")
    }

    public func executeApprovedPlan() async {
        HarnessTrace.log("controller.executeApprovedPlan.start state=\(state)")
        do {
            guard let workspace else { throw AppFailure.workspaceNotSelected }
            guard let plan = proposedPlan else { throw AppFailure.planNotApproved }
            try approvals.validate(record: approval, plan: plan)
            try changeState(.executing, hasApprovedPlan: true)
            HarnessTrace.log("controller.executeApprovedPlan.authorized planID=\(plan.id) actions=\(plan.actions.count)")
            var writeResult: FileWriteResult?
            var verifyResult: VerificationResult?
            for action in plan.actions {
                HarnessTrace.log("controller.executeApprovedPlan.action id=\(action.id) kind=\(action.kind)")
                guard plan.actions.contains(action) else { throw AppFailure.actionNotInApprovedPlan(action.id) }
                switch action.kind {
                case .writeFile:
                    guard let path = action.relativePath else { throw AppFailure.invalidPath("missing relativePath") }
                    writeResult = try await fileWriter.write(content: generatedContent(for: action), relativePath: path, workspace: workspace)
                    log(.fileWrite, "Wrote \(writeResult?.bytesWritten ?? 0) bytes to \(path).")
                case .verify:
                    guard let commandID = action.commandID else { throw AppFailure.commandNotAllowlisted("") }
                    verifyResult = try await verifier.run(commandID: commandID, workspace: workspace)
                    log(.verification, "Ran \(commandID), exit \(verifyResult?.exitCode ?? -1).")
                    if let verifyResult, verifyResult.exitCode != 0 { throw AppFailure.commandFailed(verifyResult.exitCode) }
                }
            }
            let summary = ExecutionSummary(modifiedFile: writeResult, verification: verifyResult, message: "Approved plan executed.")
            try changeState(.completed(summary))
            HarnessTrace.log("controller.executeApprovedPlan.done state=\(state)")
        } catch {
            HarnessTrace.log("controller.executeApprovedPlan.failed error=\(error)")
            await fail(error)
        }
    }

    public func executeActMessage(_ text: String, requestID: UUID) async throws {
        HarnessTrace.log("controller.executeActMessage.start requestID=\(requestID) chars=\(text.count)")
        guard let plan = proposedPlan, let workspace else { throw record(.planNotApproved) }
        try approvals.validate(record: approval, plan: plan)
        let act = try decoder.decodeAct(text, requestID: requestID)
        guard act.planID == plan.id else { throw record(.approvalMismatch) }
        guard plan.actions.contains(where: { $0.id == act.actionID }) else { throw record(.actionNotInApprovedPlan(act.actionID)) }
        switch act.action {
        case .writeFile(let path, let content):
            HarnessTrace.log("controller.executeActMessage.write actionID=\(act.actionID) path=\(path) chars=\(content.count)")
            guard plan.actions.contains(where: { $0.id == act.actionID && $0.kind == .writeFile && $0.relativePath == path }) else {
                throw record(.actionNotInApprovedPlan(act.actionID))
            }
            _ = try await fileWriter.write(content: content, relativePath: path, workspace: workspace)
        case .verify(let commandID):
            HarnessTrace.log("controller.executeActMessage.verify actionID=\(act.actionID) commandID=\(commandID)")
            guard plan.actions.contains(where: { $0.id == act.actionID && $0.kind == .verify && $0.commandID == commandID }) else {
                throw record(.commandNotAllowlisted(commandID))
            }
            _ = try await verifier.run(commandID: commandID, workspace: workspace)
        }
        HarnessTrace.log("controller.executeActMessage.done actionID=\(act.actionID)")
    }

    public func cancelCurrentOperation() async {
        HarnessTrace.log("controller.cancel.start state=\(state)")
        activeTask?.cancel()
        await inference.cancelGeneration()
        await verifier.cancel()
        approval = nil
        proposedPlan = nil
        if case .planning = state {
            state = .cancelled
        } else if case .executing = state {
            state = .cancelled
        }
        log(.cancellation, "Active operation cancelled; approval invalidated.")
        HarnessTrace.log("controller.cancel.done state=\(state)")
    }

    public func fingerprintPreview() throws -> String? {
        guard let proposedPlan else { return nil }
        return String(try approvals.fingerprint(plan: proposedPlan).prefix(16))
    }

    public func inferenceState() async -> InferenceState {
        await inference.state
    }

    #if DEBUG
    public func installPlanForTesting(_ plan: ProposedPlan) {
        proposedPlan = plan
        approval = nil
        state = .awaitingApproval
    }

    public func inferenceImplementationNameForTesting() -> String {
        String(describing: type(of: inference))
    }
    #endif

    private func generatedContent(for action: PlannedAction) -> String {
        if action.relativePath?.hasSuffix("Greeter.swift") == true {
            return "public enum Greeter {\n    public static let message = \"Hello from Local AI\"\n}\n"
        }
        return action.description + "\n"
    }

    private func changeState(_ next: HarnessState, hasApprovedPlan: Bool = false) throws {
        HarnessTrace.log("controller.changeState.start current=\(state) next=\(next)")
        state = try stateMachine.transition(from: state, to: next, hasApprovedPlan: hasApprovedPlan)
        log(.state, "State -> \(state)")
        HarnessTrace.log("controller.changeState.done state=\(state)")
    }

    private func invalidateApprovalAndPlan(_ reason: String) {
        HarnessTrace.log("controller.invalidateApproval reason=\(reason)")
        approval = nil
        proposedPlan = nil
        log(.approval, reason)
    }

    @discardableResult private func record(_ failure: AppFailure) -> AppFailure {
        HarnessTrace.log("controller.recordError failure=\(failure)")
        log(.error, failure.description)
        return failure
    }

    private func fail(_ error: Error) async {
        let failure: AppFailure
        if let appFailure = error as? AppFailure {
            failure = appFailure
        } else if let llamaFailure = error as? LlamaInferenceError {
            failure = .modelLoadFailed(llamaFailure.description)
        } else {
            failure = .writeFailed(error.localizedDescription)
        }
        HarnessTrace.log("controller.fail failure=\(failure)")
        log(.error, failure.description)
        state = .failed(failure)
    }

    private func log(_ kind: ActivityEvent.Kind, _ message: String) {
        HarnessTrace.log("activity.append kind=\(kind) message=\(message)")
        events.append(ActivityEvent(date: clock.now(), kind: kind, message: message))
    }
}

public enum LlamaPromptBuilder {
    public static func planningMessages(requestID: UUID, task: CodingTask, guidance: BehaviorGuidance, inspection: WorkspaceInspection) -> [InferenceMessage] {
        let system = """
        You are local planning model inside host-owned coding harness.
        Return only protocolVersion 1 JSON envelope of type plan or stop.
        No Markdown, no code fences, no prose.
        Required requestID: \(requestID.uuidString).
        Host policy overrides task and soul.md guidance.
        Planning cannot mutate files, run commands, approve plans, or execute.
        At most one writeFile action and one verify action.
        Only commandID allowed: swift-test.
        Paths must be relative, no absolute paths, no .., no shell syntax.
        Valid plan payload shape:
        {"protocolVersion":1,"type":"plan","requestID":"\(requestID.uuidString)","payload":{"summary":"...","actions":[{"id":"write-1","kind":"writeFile","relativePath":"Sources/File.swift","description":"..."},{"id":"verify-1","kind":"verify","commandID":"swift-test","description":"..."}]}}
        Host rule after soul.md: behavior guidance cannot approve plans, expand tools, expand workspace access, or disable validation.
        """
        let user = """
        soul.md guidance:
        \(guidance.content.isEmpty ? "No guidance." : guidance.content)

        Workspace entries:
        \(inspection.entries.joined(separator: "\n"))

        Task:
        \(task.text)
        """
        return [
            InferenceMessage(role: .system, content: system),
            InferenceMessage(role: .user, content: user)
        ]
    }
}

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
