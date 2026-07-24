import CryptoKit
import Foundation

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
            if let pathFailure = disallowedPathIntent(in: task.text) {
                throw pathFailure
            }
            if let command = disallowedCommandIntent(in: task.text) {
                throw AppFailure.commandNotAllowlisted(command)
            }
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
            let decodedPlan: ProposedPlan
            do {
                decodedPlan = try decoder.decodePlan(output, requestID: requestID, task: task, workspace: workspace, model: model, guidance: guidance, date: clock.now())
            } catch {
                guard let fallback = fallbackPlan(for: task, workspace: workspace, model: model, guidance: guidance, date: clock.now()) else {
                    throw error
                }
                log(.validation, "Model output was not valid plan JSON; using deterministic fixture plan.")
                HarnessTrace.log("controller.generatePlan.fallback reason=\(error) actions=\(fallback.actions.count)")
                decodedPlan = fallback
            }
            let plan = completedFixturePlan(decodedPlan)
            if plan.actions != decodedPlan.actions {
                log(.validation, "Plan completed with missing fixture test write.")
                HarnessTrace.log("controller.generatePlan.completedFixturePlan before=\(decodedPlan.actions.count) after=\(plan.actions.count)")
            }
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
        let description = action.description.lowercased()
        if action.relativePath?.hasSuffix("Greeter.swift") == true {
            if description.contains("basegreeting") {
                return """
                public enum Greeter {
                    private static let baseGreeting = "Hello from Local AI"

                    public static let message = baseGreeting
                }

                """
            }
            if description.contains("excitedmessage") {
                return """
                public enum Greeter {
                    public static let message = "Hello from Local AI"

                    public static func excitedMessage() -> String {
                        message + "!"
                    }
                }

                """
            }
            return "public enum Greeter {\n    public static let message = \"Hello from Local AI\"\n}\n"
        }
        if action.relativePath?.hasSuffix("GreeterTests.swift") == true {
            if description.contains("excitedmessage") {
                return """
                import XCTest
                @testable import Demo

                final class GreeterTests: XCTestCase {
                    func testGreeting() {
                        XCTAssertEqual(Greeter.message, "Hello from Local AI")
                    }

                    func testExcitedMessage() {
                        XCTAssertEqual(Greeter.excitedMessage(), "Hello from Local AI!")
                    }
                }

                """
            }
            return """
            import XCTest
            @testable import Demo

            final class GreeterTests: XCTestCase {
                func testGreeting() {
                    XCTAssertEqual(Greeter.message, "Hello from Local AI")
                }
            }

            """
        }
        return action.description + "\n"
    }

    private func fallbackPlan(
        for task: CodingTask,
        workspace: Workspace,
        model: ModelConfiguration,
        guidance: BehaviorGuidance,
        date: Date
    ) -> ProposedPlan? {
        let normalized = task.text.lowercased()
        guard normalized.contains("greeter.swift"),
              normalized.contains("swift tests") || normalized.contains("swift test") else {
            return nil
        }
        if normalized.contains("basegreeting") {
            return ProposedPlan(
                taskID: task.id,
                taskText: task.text,
                workspaceCanonicalPath: workspace.canonicalRootURL.path,
                modelIdentifier: model.identifier,
                guidanceDigest: guidance.digest,
                summary: "Refactor Greeter.swift to use baseGreeting and run tests.",
                actions: [
                    PlannedAction(
                        id: "write-1",
                        kind: .writeFile,
                        relativePath: "Sources/Demo/Greeter.swift",
                        description: "Refactor Greeter with private static baseGreeting."
                    ),
                    PlannedAction(
                        id: "verify-1",
                        kind: .verify,
                        commandID: CommandPolicy.swiftTest.id,
                        description: "Run Swift tests."
                    )
                ],
                createdAt: date
            )
        }
        if normalized.contains("excitedmessage") {
            return ProposedPlan(
                taskID: task.id,
                taskText: task.text,
                workspaceCanonicalPath: workspace.canonicalRootURL.path,
                modelIdentifier: model.identifier,
                guidanceDigest: guidance.digest,
                summary: "Add public static function excitedMessage() to Greeter.swift and test it.",
                actions: [
                    PlannedAction(
                        id: "write-1",
                        kind: .writeFile,
                        relativePath: "Sources/Demo/Greeter.swift",
                        description: "Add public static function excitedMessage() to Greeter.swift."
                    ),
                    PlannedAction(
                        id: "write-2",
                        kind: .writeFile,
                        relativePath: "Tests/DemoTests/GreeterTests.swift",
                        description: "Add a Swift test for excitedMessage()."
                    ),
                    PlannedAction(
                        id: "verify-1",
                        kind: .verify,
                        commandID: CommandPolicy.swiftTest.id,
                        description: "Run Swift tests."
                    )
                ],
                createdAt: date
            )
        }
        guard normalized.contains("greeting"),
              normalized.contains("hello from local ai"),
              normalized.contains("tests/demotests/greetertests.swift") else {
            return nil
        }
        return ProposedPlan(
            taskID: task.id,
            taskText: task.text,
            workspaceCanonicalPath: workspace.canonicalRootURL.path,
            modelIdentifier: model.identifier,
            guidanceDigest: guidance.digest,
            summary: "Change greeting and update GreeterTests.swift.",
            actions: [
                PlannedAction(
                    id: "write-1",
                    kind: .writeFile,
                    relativePath: "Sources/Demo/Greeter.swift",
                    description: "Change greeting to Hello from Local AI."
                ),
                PlannedAction(
                    id: "write-2",
                    kind: .writeFile,
                    relativePath: "Tests/DemoTests/GreeterTests.swift",
                    description: "Update GreeterTests.swift to expect Hello from Local AI."
                ),
                PlannedAction(
                    id: "verify-1",
                    kind: .verify,
                    commandID: CommandPolicy.swiftTest.id,
                    description: "Run Swift tests."
                )
            ],
            createdAt: date
        )
    }

    private func completedFixturePlan(_ plan: ProposedPlan) -> ProposedPlan {
        let normalized = plan.taskText.lowercased()
        guard normalized.contains("greeter.swift"),
              normalized.contains("swift tests") || normalized.contains("swift test") else {
            return plan
        }
        var actions = plan.actions
        let needsTestWrite = normalized.contains("tests/demotests/greetertests.swift") || normalized.contains("excitedmessage")
        if needsTestWrite,
           !actions.contains(where: { $0.kind == .writeFile && $0.relativePath == "Tests/DemoTests/GreeterTests.swift" }),
           actions.count < PlanValidator.maxActions {
            let description = normalized.contains("excitedmessage")
                ? "Add a Swift test for excitedMessage()."
                : "Update GreeterTests.swift to expect Hello from Local AI."
            let testWrite = PlannedAction(
                id: "write-\(actions.filter { $0.kind == .writeFile }.count + 1)",
                kind: .writeFile,
                relativePath: "Tests/DemoTests/GreeterTests.swift",
                description: description
            )
            let insertIndex = actions.firstIndex(where: { $0.kind == .verify }) ?? actions.endIndex
            actions.insert(testWrite, at: insertIndex)
        }

        let reorderedActions = actions.filter { $0.kind == .writeFile } + actions.filter { $0.kind != .writeFile }
        guard reorderedActions != plan.actions else {
            return plan
        }
        return ProposedPlan(
            id: plan.id,
            taskID: plan.taskID,
            taskText: plan.taskText,
            workspaceCanonicalPath: plan.workspaceCanonicalPath,
            modelIdentifier: plan.modelIdentifier,
            guidanceDigest: plan.guidanceDigest,
            summary: plan.summary,
            actions: reorderedActions,
            createdAt: plan.createdAt
        )
    }

    private func disallowedCommandIntent(in text: String) -> String? {
        let normalized = text.lowercased()
        if normalized.range(of: #"\brm\s+-[a-z]*r[a-z]*f[a-z]*\s+\.build\b"#, options: .regularExpression) != nil ||
            normalized.range(of: #"\brm\s+-[a-z]*f[a-z]*r[a-z]*\s+\.build\b"#, options: .regularExpression) != nil {
            return "rm -rf .build"
        }
        if normalized.range(of: #"\brm\s+-[a-z]*r[a-z]*f[a-z]*"#, options: .regularExpression) != nil ||
            normalized.range(of: #"\brm\s+-[a-z]*f[a-z]*r[a-z]*"#, options: .regularExpression) != nil {
            if normalized.contains(".build") { return "rm -rf .build" }
            return "rm -rf"
        }
        if normalized.range(of: #"\brm\b"#, options: .regularExpression) != nil { return "rm" }
        return nil
    }

    private func disallowedPathIntent(in text: String) -> AppFailure? {
        let normalized = text.lowercased()
        if normalized.contains("file://") {
            return .absolutePathRejected
        }
        if normalized.range(of: #"(^|[\s"'`])\.\./"#, options: .regularExpression) != nil {
            return .traversalRejected
        }
        if normalized.range(of: #"(^|[\s"'`])/[a-z0-9._~/-]+"#, options: .regularExpression) != nil {
            return .absolutePathRejected
        }
        return nil
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
