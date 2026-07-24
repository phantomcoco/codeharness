import XCTest
@testable import LocalAICodingHarnessCore

final class HarnessTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 100)

    func testWriteAndCommandCannotRunBeforeApproval() async throws {
        let spies = Spies()
        let controller = makeController(spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        await controller.setTaskText("change greeting")
        try await setPlan(on: controller, workspace: workspace, model: model)

        await controller.executeApprovedPlan()

        let writerCalls = await spies.writer.calls
        let runnerCalls = await spies.runner.calls
        XCTAssertEqual(writerCalls, 0)
        XCTAssertEqual(runnerCalls, 0)
        if case .failed(let failure) = await controller.state {
            XCTAssertEqual(failure, .planNotApproved)
        } else {
            XCTFail("expected failed")
        }
    }

    func testApprovalEnablesOnlyApprovedExecuteActions() async throws {
        let spies = Spies()
        let controller = makeController(spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        await controller.setTaskText("change greeting")
        let plan = try await setPlan(on: controller, workspace: workspace, model: model)
        try await controller.approvePlan()

        let requestID = UUID()
        let validWrite = actJSON(requestID: requestID, planID: plan.id, actionID: "write-1", body: #""action":{"kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","content":"ok"}"#)
        try await controller.executeActMessage(validWrite, requestID: requestID)
        let writerCalls = await spies.writer.calls
        XCTAssertEqual(writerCalls, 1)

        let badFile = actJSON(requestID: requestID, planID: plan.id, actionID: "write-1", body: #""action":{"kind":"writeFile","relativePath":"Sources/Demo/Other.swift","content":"ok"}"#)
        await XCTAssertThrowsAsync(try await controller.executeActMessage(badFile, requestID: requestID))

        let badCommand = actJSON(requestID: requestID, planID: plan.id, actionID: "verify-1", body: #""action":{"kind":"verify","commandID":"rm"}"#)
        await XCTAssertThrowsAsync(try await controller.executeActMessage(badCommand, requestID: requestID))

        let newAction = actJSON(requestID: requestID, planID: plan.id, actionID: "write-999", body: #""action":{"kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","content":"ok"}"#)
        await XCTAssertThrowsAsync(try await controller.executeActMessage(newAction, requestID: requestID))
    }

    func testChangedPlanInvalidatesApprovalAndRejectedPlanCannotExecute() async throws {
        let spies = Spies()
        let controller = makeController(spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        await controller.setTaskText("change greeting")
        _ = try await setPlan(on: controller, workspace: workspace, model: model)
        try await controller.approvePlan()
        await controller.setTaskText("changed task")
        await controller.executeApprovedPlan()
        let writerCalls = await spies.writer.calls
        XCTAssertEqual(writerCalls, 0)

        let controller2 = makeController(spies: Spies())
        await controller2.selectWorkspace(workspace)
        await controller2.selectModel(model)
        await controller2.setTaskText("change greeting")
        _ = try await setPlan(on: controller2, workspace: workspace, model: model)
        await controller2.rejectPlan()
        await controller2.executeApprovedPlan()
        if case .failed(let failure) = await controller2.state {
            XCTAssertEqual(failure, .planNotApproved)
        } else {
            XCTFail("expected failed")
        }
    }

    func testOutOfWorkspacePathsAreRejected() async throws {
        let workspace = try makeWorkspace()
        let validator = WorkspaceSecurityValidator()
        for path in ["../secret.txt", "../../secret.txt", "/etc/passwd", "file:///tmp/file.swift", #"C:\Windows\System32"#] {
            XCTAssertThrowsError(try validator.resolve(relativePath: path, in: workspace))
        }
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("outside-\(UUID().uuidString)")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        let link = workspace.canonicalRootURL.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try validator.resolve(relativePath: "link/secret.txt", in: workspace))
    }

    func testMalformedAndWrongStateOutputProduceVisibleError() async throws {
        let fake = FakeInferenceEngine(responses: [.success("{ nope")])
        let spies = Spies()
        let controller = makeController(inference: fake, spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        try await controller.loadModel()
        await controller.setTaskText("task")
        await controller.generatePlan()
        let proposedPlan = await controller.proposedPlan
        let writerCalls = await spies.writer.calls
        XCTAssertNil(proposedPlan)
        XCTAssertEqual(writerCalls, 0)

        let req = UUID()
        let wrong = actJSON(requestID: req, planID: UUID(), actionID: "a", body: #""action":{"kind":"verify","commandID":"swift-test"}"#)
        let fake2 = FakeInferenceEngine(responses: [.success(wrong)])
        let controller2 = makeController(inference: fake2, spies: Spies())
        await controller2.selectWorkspace(workspace)
        await controller2.selectModel(model)
        try await controller2.loadModel()
        await controller2.setTaskText("task")
        await controller2.generatePlan()
        if case .failed(let failure) = await controller2.state {
            XCTAssertEqual(failure, .wrongMessageForState("expected plan"))
        } else {
            XCTFail("expected wrong state failure")
        }
    }

    func testPlanDecoderAcceptsFencedJSONEnvelope() throws {
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        let requestID = UUID()
        let task = CodingTask(text: "task")
        let text = """
        Here is the plan:
        ```json
        {"protocolVersion":1,"type":"plan","requestID":"\(requestID.uuidString)","payload":{"summary":"Update greeting and run tests.","actions":[{"id":"write-1","kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","description":"Replace greeting."},{"id":"verify-1","kind":"verify","commandID":"swift-test","description":"Run Swift tests."}]}}
        ```
        """

        let plan = try StructuredMessageDecoder().decodePlan(
            text,
            requestID: requestID,
            task: task,
            workspace: workspace,
            model: model,
            guidance: .none,
            date: date
        )

        XCTAssertEqual(plan.actions.count, 2)
        XCTAssertEqual(plan.actions.first?.relativePath, "Sources/Demo/Greeter.swift")
    }

    func testActDecoderAcceptsFencedJSONEnvelope() throws {
        let requestID = UUID()
        let planID = UUID()
        let text = """
        ```json
        {"protocolVersion":1,"type":"act","requestID":"\(requestID.uuidString)","payload":{"planID":"\(planID.uuidString)","actionID":"verify-1","action":{"kind":"verify","commandID":"swift-test"}}}
        ```
        """

        let act = try StructuredMessageDecoder().decodeAct(text, requestID: requestID)

        XCTAssertEqual(act.planID, planID)
        XCTAssertEqual(act.actionID, "verify-1")
    }

    func testTooManyWritesAndBadCommandsRejected() async throws {
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        let plan = ProposedPlan(
            taskID: UUID(),
            taskText: "task",
            workspaceCanonicalPath: workspace.canonicalRootURL.path,
            modelIdentifier: model.identifier,
            guidanceDigest: BehaviorGuidance.none.digest,
            summary: "bad",
            actions: [
                PlannedAction(id: "w1", kind: .writeFile, relativePath: "a.swift", description: "a"),
                PlannedAction(id: "w2", kind: .writeFile, relativePath: "b.swift", description: "b")
            ],
            createdAt: date
        )
        XCTAssertThrowsError(try PlanValidator().validate(plan: plan, workspace: workspace))

        for command in ["rm", "bash", "zsh", "curl", "python", "xcodebuild", "swift build && rm -rf"] {
            let commandPlan = ProposedPlan(taskID: UUID(), taskText: "task", workspaceCanonicalPath: workspace.canonicalRootURL.path, modelIdentifier: model.identifier, guidanceDigest: "", summary: "bad", actions: [
                PlannedAction(id: "v1", kind: .verify, commandID: command, description: "bad")
            ], createdAt: date)
            XCTAssertThrowsError(try PlanValidator().validate(plan: commandPlan, workspace: workspace))
        }
    }

    func testCancellationStopsInference() async throws {
        let requestID = UUID()
        let fake = FakeInferenceEngine(responses: [.delayed(planJSON(requestID: requestID))])
        let spies = Spies()
        let controller = makeController(inference: fake, spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        try await controller.loadModel()
        await controller.setTaskText("task")
        let task = Task { await controller.generatePlan() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.cancelCurrentOperation()
        await task.value
        let approval = await controller.approval
        let writerCalls = await spies.writer.calls
        XCTAssertNil(approval)
        XCTAssertEqual(writerCalls, 0)
    }

    func testProductionAndTestingContainersSelectExpectedInference() async throws {
        let productionName = await AppContainer.production().controller.inferenceImplementationNameForTesting()
        XCTAssertEqual(productionName, "LlamaInferenceEngine")

        let testingName = await AppContainer.testing().controller.inferenceImplementationNameForTesting()
        XCTAssertEqual(testingName, "FakeInferenceEngine")
    }

    func testFakeGenerationIsDeterministicAndRequiresLoadedModel() async throws {
        let request = InferenceRequest(prompt: "hi")
        let unloaded = FakeInferenceEngine(responses: [.success("one")])
        var unloadedError: Error?
        do {
            for try await _ in await unloaded.generate(request: request) {}
        } catch {
            unloadedError = error
        }
        XCTAssertEqual(unloadedError as? AppFailure, .modelNotLoaded)

        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        let fake = FakeInferenceEngine(responses: [.success("one"), .success("two")])
        try await fake.loadModel(configuration: model)
        let first = try await collect(await fake.generate(request: request))
        let second = try await collect(await fake.generate(request: request))
        XCTAssertEqual(first, "one")
        XCTAssertEqual(second, "two")
    }

    func testSmokeAcceptsFencedCompactJSON() async throws {
        let response = """
        ```json
        {"type":"stop","reason":"native inference is working"}
        ```
        """
        let fake = FakeInferenceEngine(responses: [.success(response)])
        let controller = makeController(inference: fake, spies: Spies())
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        try await controller.loadModel()

        let result = try await controller.runNativeSmokeTest()

        XCTAssertTrue(result.completed)
    }

    func testSmokeRejectsWrongJSON() async throws {
        let fake = FakeInferenceEngine(responses: [.success(#"{"type":"stop","reason":"wrong"}"#)])
        let controller = makeController(inference: fake, spies: Spies())
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        try await controller.loadModel()

        let result = try await controller.runNativeSmokeTest()

        XCTAssertFalse(result.completed)
    }

    func testChangingModelInvalidatesApprovalAndCancelsInference() async throws {
        let requestID = UUID()
        let fake = FakeInferenceEngine(responses: [.delayed(planJSON(requestID: requestID))])
        let spies = Spies()
        let controller = makeController(inference: fake, spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        let otherModelURL = workspace.canonicalRootURL.appendingPathComponent("other.gguf")
        try Data([1]).write(to: otherModelURL)
        let otherModel = ModelConfiguration(url: otherModelURL, canonicalPath: otherModelURL.path, fileSizeBytes: 1)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        try await controller.loadModel()
        await controller.setTaskText("task")
        let task = Task { await controller.generatePlan() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.selectModel(otherModel)
        await task.value
        let approval = await controller.approval
        let proposedPlan = await controller.proposedPlan
        let writerCalls = await spies.writer.calls
        XCTAssertNil(approval)
        XCTAssertNil(proposedPlan)
        XCTAssertEqual(writerCalls, 0)
    }

    func testModelLoadFailureDoesNotProduceFakeSuccess() async throws {
        let fake = FakeInferenceEngine(responses: [.success(planJSON(requestID: UUID()))])
        let spies = Spies()
        let controller = makeController(inference: fake, spies: spies)
        let workspace = try makeWorkspace()
        let missing = workspace.canonicalRootURL.appendingPathComponent("missing.gguf")
        let model = ModelConfiguration(url: missing, canonicalPath: missing.path, fileSizeBytes: 0)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        await XCTAssertThrowsAsync(try await controller.loadModel())
        let proposedPlan = await controller.proposedPlan
        let generateCalls = await fake.generateCalls
        XCTAssertNil(proposedPlan)
        XCTAssertEqual(generateCalls, 0)
    }

    func testCancellationStopsVerification() async throws {
        let runner = SpyVerificationRunner(delay: 5)
        let spies = Spies(runner: runner)
        let controller = makeController(spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        await controller.setTaskText("task")
        _ = try await setPlan(on: controller, workspace: workspace, model: model)
        try await controller.approvePlan()
        let task = Task { await controller.executeApprovedPlan() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.cancelCurrentOperation()
        await task.value
        let wasCancelled = await runner.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testValidVerticalSliceCompletes() async throws {
        let spies = Spies()
        let controller = makeController(spies: spies)
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        await controller.setTaskText("task")
        _ = try await setPlan(on: controller, workspace: workspace, model: model)
        try await controller.approvePlan()
        await controller.executeApprovedPlan()
        let writerCalls = await spies.writer.calls
        let runnerCalls = await spies.runner.calls
        XCTAssertEqual(writerCalls, 1)
        XCTAssertEqual(runnerCalls, 1)
        if case .completed(let summary) = await controller.state {
            XCTAssertEqual(summary.verification?.exitCode, 0)
        } else {
            XCTFail("expected completed")
        }
    }

    private func makeController(inference: FakeInferenceEngine = FakeInferenceEngine(), spies: Spies) -> CodingHarnessController {
        CodingHarnessController(
            inference: inference,
            inspector: SpyInspector(),
            fileWriter: spies.writer,
            verifier: spies.runner,
            clock: FixedClock(date)
        )
    }

    @discardableResult
    private func setPlan(on controller: CodingHarnessController, workspace: Workspace, model: ModelConfiguration) async throws -> ProposedPlan {
        let task = CodingTask(text: "task")
        await controller.setTaskText(task.text)
        let plan = ProposedPlan(
            taskID: (await controller.task)!.id,
            taskText: task.text,
            workspaceCanonicalPath: workspace.canonicalRootURL.path,
            modelIdentifier: model.identifier,
            guidanceDigest: BehaviorGuidance.none.digest,
            summary: "Update greeting and run tests.",
            actions: [
                PlannedAction(id: "write-1", kind: .writeFile, relativePath: "Sources/Demo/Greeter.swift", description: "Replace greeting."),
                PlannedAction(id: "verify-1", kind: .verify, commandID: "swift-test", description: "Run Swift tests.")
            ],
            createdAt: date
        )
        await controller.installPlanForTesting(plan)
        return plan
    }

    private func makeWorkspace() throws -> Workspace {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("harness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceSecurityValidator().canonicalWorkspace(from: url)
    }

    private func makeModel(_ workspace: Workspace) throws -> ModelConfiguration {
        let url = workspace.canonicalRootURL.appendingPathComponent("model.gguf")
        try Data([0]).write(to: url)
        return ModelConfiguration(url: url, canonicalPath: url.path, fileSizeBytes: 1)
    }
}

private struct Spies {
    let writer: SpyFileWriter
    let runner: SpyVerificationRunner
    init(writer: SpyFileWriter = SpyFileWriter(), runner: SpyVerificationRunner = SpyVerificationRunner()) {
        self.writer = writer
        self.runner = runner
    }
}

private struct SpyInspector: WorkspaceInspecting {
    func inspect(workspace: Workspace) async throws -> WorkspaceInspection {
        WorkspaceInspection(entries: ["Sources/Demo/Greeter.swift"], filePreviews: [:])
    }
}

private actor SpyFileWriter: FileWriting {
    private(set) var calls = 0
    func write(content: String, relativePath: String, workspace: Workspace) async throws -> FileWriteResult {
        calls += 1
        return FileWriteResult(relativePath: relativePath, resolvedPath: workspace.canonicalRootURL.appendingPathComponent(relativePath).path, bytesWritten: content.utf8.count)
    }
}

private actor SpyVerificationRunner: VerificationRunning {
    private(set) var calls = 0
    private(set) var wasCancelled = false
    let delay: UInt64
    init(delay: UInt64 = 0) { self.delay = delay }
    func run(commandID: String, workspace: Workspace) async throws -> VerificationResult {
        calls += 1
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
        return VerificationResult(commandID: commandID, exitCode: 0, output: "ok", duration: 0.1, timedOut: false, cancelled: false)
    }
    func cancel() async { wasCancelled = true }
}

private func planJSON(requestID: UUID) -> String {
    """
    {"protocolVersion":1,"type":"plan","requestID":"\(requestID.uuidString)","payload":{"summary":"Update greeting and run tests.","actions":[{"id":"write-1","kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","description":"Replace greeting."},{"id":"verify-1","kind":"verify","commandID":"swift-test","description":"Run Swift tests."}]}}
    """
}

private func actJSON(requestID: UUID, planID: UUID, actionID: String, body: String) -> String {
    """
    {"protocolVersion":1,"type":"act","requestID":"\(requestID.uuidString)","payload":{"planID":"\(planID.uuidString)","actionID":"\(actionID)",\(body)}}
    """
}

private func XCTAssertThrowsAsync(
    _ expression: @autoclosure @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected throw", file: file, line: line)
    } catch {}
}

private func collect(_ stream: AsyncThrowingStream<InferenceEvent, Error>) async throws -> String {
    var output = ""
    for try await event in stream {
        if case .token(let text) = event {
            output += text
        }
    }
    return output
}
