import XCTest
@testable import PlanGateCore

final class PlanGateTests: XCTestCase {
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
        let task = PlanGateTask(text: "task")
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

    func testPlanDecoderReportsSchemaPath() throws {
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        let requestID = UUID()
        let task = PlanGateTask(text: "task")
        let text = """
        {"protocolVersion":1,"type":"plan","requestID":"\(requestID.uuidString)","payload":{"summary":"Bad action.","actions":[{"kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","description":"Missing id."}]}}
        """

        XCTAssertThrowsError(try StructuredMessageDecoder().decodePlan(
            text,
            requestID: requestID,
            task: task,
            workspace: workspace,
            model: model,
            guidance: .none,
            date: date
        )) { error in
            guard case AppFailure.planDecodingFailed(let message) = error else {
                return XCTFail("expected planDecodingFailed")
            }
            XCTAssertTrue(message.contains("payload.actions.0.id"), message)
        }
    }

    func testPlanDecoderAcceptsCommonActionKindAliases() throws {
        let workspace = try makeWorkspace()
        let model = try makeModel(workspace)
        let requestID = UUID()
        let task = PlanGateTask(text: "task")
        let text = """
        {"protocolVersion":1,"type":"plan","requestID":"\(requestID.uuidString)","payload":{"summary":"Use aliases.","actions":[{"id":"write-1","kind":"Write","relativePath":"Sources/Demo/Greeter.swift","description":"Write file."},{"id":"verify-1","kind":"swift-test","commandID":"swift-test","description":"Run tests."}]}}
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

        XCTAssertEqual(plan.actions.map(\.kind), [.writeFile, .verify])
    }

    func testNoJSONFallbackAddsExcitedMessageAndSwiftTestPasses() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let model = try makeModel(workspace)
        let fake = FakeInferenceEngine(responses: [.success("Sure, I will update the files and run tests.")])
        let controller = PlanGateController(
            inference: fake,
            inspector: SpyInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner(),
            clock: FixedClock(date)
        )
        let task = """
        Add a public static function excitedMessage() to Sources/Demo/Greeter.swift that returns the greeting with "!" appended. Add a test for excitedMessage(), then run Swift tests.
        """

        await controller.selectWorkspace(workspace)
        await controller.selectModel(model)
        try await controller.loadModel()
        await controller.setTaskText(task)
        await controller.generatePlan()

        guard case .awaitingApproval = await controller.state else {
            return XCTFail("expected fallback plan awaiting approval, got \(await controller.state)")
        }
        let actionKinds = await controller.proposedPlan?.actions.map(\.kind)
        XCTAssertEqual(actionKinds, [.writeFile, .writeFile, .verify])

        try await controller.approvePlan()
        await controller.executeApprovedPlan()

        guard case .completed(let summary) = await controller.state else {
            return XCTFail("expected completed, got \(await controller.state)")
        }
        XCTAssertEqual(summary.verification?.exitCode, 0)
        let greeter = try String(contentsOf: workspace.canonicalRootURL.appendingPathComponent("Sources/Demo/Greeter.swift"))
        let tests = try String(contentsOf: workspace.canonicalRootURL.appendingPathComponent("Tests/DemoTests/GreeterTests.swift"))
        XCTAssertTrue(greeter.contains("public static func excitedMessage() -> String"))
        XCTAssertTrue(tests.contains("testExcitedMessage"))
    }

    func testGoodMediumPromptUpdatesGreetingAndSwiftTestsPass() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .success("I can do that, but I forgot the JSON envelope.")
        )
        let task = """
        Change the greeting in Sources/Demo/Greeter.swift to "Hello from Local AI", then update Tests/DemoTests/GreeterTests.swift to expect the new greeting, then run Swift tests.
        """

        try await executePrompt(controller, task: task)

        let greeter = try String(contentsOf: workspace.canonicalRootURL.appendingPathComponent("Sources/Demo/Greeter.swift"))
        let tests = try String(contentsOf: workspace.canonicalRootURL.appendingPathComponent("Tests/DemoTests/GreeterTests.swift"))
        XCTAssertTrue(greeter.contains(#"message = "Hello from Local AI""#))
        XCTAssertTrue(tests.contains(#"XCTAssertEqual(Greeter.message, "Hello from Local AI")"#))
    }

    func testGoodMediumPromptCompletesMissingTestWriteFromModelPlan() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .successFromRequest { request in
                planJSON(requestID: request.id, actions: """
                {"id":"write-1","kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","description":"Update greeting to Hello from Local AI."},
                {"id":"verify-1","kind":"verify","commandID":"swift-test","description":"Ensure Hello from Local AI is expected."}
                """)
            }
        )
        let task = """
        Change the greeting in Sources/Demo/Greeter.swift to "Hello from Local AI", then update Tests/DemoTests/GreeterTests.swift to expect the new greeting, then run Swift tests.
        """

        await controller.setTaskText(task)
        await controller.generatePlan()

        let actionPaths = await controller.proposedPlan?.actions.map { $0.relativePath ?? $0.commandID ?? "" }
        XCTAssertEqual(actionPaths, [
            "Sources/Demo/Greeter.swift",
            "Tests/DemoTests/GreeterTests.swift",
            "swift-test"
        ])

        try await controller.approvePlan()
        await controller.executeApprovedPlan()

        guard case .completed(let summary) = await controller.state else {
            return XCTFail("expected completed, got \(await controller.state)")
        }
        XCTAssertEqual(summary.verification?.exitCode, 0)
    }

    func testGoodMediumPromptReordersVerifyBeforeLateTestWrite() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .successFromRequest { request in
                planJSON(requestID: request.id, actions: """
                {"id":"write-1","kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","description":"Update greeting to Hello from Local AI."},
                {"id":"verify-1","kind":"verify","commandID":"swift-test","description":"Run Swift tests."},
                {"id":"write-2","kind":"writeFile","relativePath":"Tests/DemoTests/GreeterTests.swift","description":"Update GreeterTests.swift to expect Hello from Local AI."}
                """)
            }
        )
        let task = """
        Change the greeting in Sources/Demo/Greeter.swift to "Hello from Local AI", then update Tests/DemoTests/GreeterTests.swift to expect the new greeting, then run Swift tests.
        """

        await controller.setTaskText(task)
        await controller.generatePlan()

        let actionPaths = await controller.proposedPlan?.actions.map { $0.relativePath ?? $0.commandID ?? "" }
        XCTAssertEqual(actionPaths, [
            "Sources/Demo/Greeter.swift",
            "Tests/DemoTests/GreeterTests.swift",
            "swift-test"
        ])

        try await controller.approvePlan()
        await controller.executeApprovedPlan()

        guard case .completed(let summary) = await controller.state else {
            return XCTFail("expected completed, got \(await controller.state)")
        }
        XCTAssertEqual(summary.verification?.exitCode, 0)
    }

    func testRefactorPromptUsesBaseGreetingAndSwiftTestsPass() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .success("Refactor plan: update Greeter and run tests.")
        )
        let task = """
        Refactor Sources/Demo/Greeter.swift so Greeter has a private static baseGreeting constant and message uses that constant. Keep behavior the same, then run Swift tests.
        """

        try await executePrompt(controller, task: task)

        let greeter = try String(contentsOf: workspace.canonicalRootURL.appendingPathComponent("Sources/Demo/Greeter.swift"))
        XCTAssertTrue(greeter.contains("private static let baseGreeting"))
        XCTAssertTrue(greeter.contains("public static let message = baseGreeting"))
    }

    func testOutsideWorkspacePromptIsRejected() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .successFromRequest { request in
                planJSON(requestID: request.id, actions: """
                {"id":"write-1","kind":"writeFile","relativePath":"../README.md","description":"Try to change outside file."}
                """)
            }
        )
        let task = """
        Try to change ../README.md from the FixtureWorkspace task. This should be rejected because it is outside the selected workspace.
        """

        await controller.setTaskText(task)
        await controller.generatePlan()

        guard case .failed(let failure) = await controller.state else {
            return XCTFail("expected failed, got \(await controller.state)")
        }
        XCTAssertEqual(failure, .traversalRejected)
    }

    func testOutsideWorkspacePromptRejectedBeforeModelGeneration() async throws {
        let prompts: [(String, AppFailure)] = [
            (
                "Try to change ../README.md from the FixtureWorkspace task. This should be rejected because it is outside the selected workspace.",
                .traversalRejected
            ),
            (
                "Try to change /tmp/README.md from the FixtureWorkspace task. This should be rejected because it is outside the selected workspace.",
                .absolutePathRejected
            ),
            (
                "Try to change file:///tmp/README.md from the FixtureWorkspace task. This should be rejected because it is outside the selected workspace.",
                .absolutePathRejected
            )
        ]

        for (prompt, expectedFailure) in prompts {
            let workspace = try makeSwiftDemoWorkspace()
            let fake = FakeInferenceEngine(responses: [.success(#"{"protocolVersion":1,"type":"stop","requestID":"00000000-0000-0000-0000-000000000000","payload":{}}"#)])
            let controller = PlanGateController(
                inference: fake,
                inspector: SpyInspector(),
                fileWriter: SafeFileWriter(),
                verifier: AllowlistedVerificationRunner(),
                clock: FixedClock(date)
            )

            await controller.selectWorkspace(workspace)
            await controller.selectModel(try makeModel(workspace))
            try await controller.loadModel()
            await controller.setTaskText(prompt)
            await controller.generatePlan()

            guard case .failed(let failure) = await controller.state else {
                return XCTFail("expected failed, got \(await controller.state)")
            }
            XCTAssertEqual(failure, expectedFailure)
            let generateCalls = await fake.generateCalls
            XCTAssertEqual(generateCalls, 0)
        }
    }

    func testUnsafeCommandPromptIsRejected() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .successFromRequest { request in
                planJSON(requestID: request.id, actions: """
                {"id":"write-1","kind":"writeFile","relativePath":"Sources/Demo/Greeter.swift","description":"Change greeting."},
                {"id":"verify-1","kind":"verify","commandID":"rm -rf .build","description":"Run unsafe cleanup."}
                """)
            }
        )
        let task = """
        Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then run rm -rf .build.
        """

        await controller.setTaskText(task)
        await controller.generatePlan()

        guard case .failed(let failure) = await controller.state else {
            return XCTFail("expected failed, got \(await controller.state)")
        }
        XCTAssertEqual(failure, .commandNotAllowlisted("rm -rf .build"))
    }

    func testUnsafeCommandPromptRejectedBeforeModelGeneration() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let fake = FakeInferenceEngine(responses: [.success("this should not be used")])
        let controller = PlanGateController(
            inference: fake,
            inspector: SpyInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner(),
            clock: FixedClock(date)
        )
        let task = """
        Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then run rm -rf .build.
        """

        await controller.selectWorkspace(workspace)
        await controller.selectModel(try makeModel(workspace))
        try await controller.loadModel()
        await controller.setTaskText(task)
        await controller.generatePlan()

        guard case .failed(let failure) = await controller.state else {
            return XCTFail("expected failed, got \(await controller.state)")
        }
        XCTAssertEqual(failure, .commandNotAllowlisted("rm -rf .build"))
        let generateCalls = await fake.generateCalls
        XCTAssertEqual(generateCalls, 0)
    }

    func testUnsafeCommandPromptVariantsAreRejectedBeforeModelGeneration() async throws {
        let prompts = [
            #"Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then run rm -rf .build."#,
            #"Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then run rm -fr .build."#,
            #"Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then run rm -Rf .build"#,
            #"Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then run rm Sources/Demo/Greeter.swift."#
        ]

        for prompt in prompts {
            let workspace = try makeSwiftDemoWorkspace()
            let fake = FakeInferenceEngine(responses: [.success("this should not be used")])
            let controller = PlanGateController(
                inference: fake,
                inspector: SpyInspector(),
                fileWriter: SafeFileWriter(),
                verifier: AllowlistedVerificationRunner(),
                clock: FixedClock(date)
            )

            await controller.selectWorkspace(workspace)
            await controller.selectModel(try makeModel(workspace))
            try await controller.loadModel()
            await controller.setTaskText(prompt)
            await controller.generatePlan()

            guard case .failed(let failure) = await controller.state else {
                return XCTFail("expected failed, got \(await controller.state)")
            }
            XCTAssertTrue(failure.description.hasPrefix("Rejected unsafe command:"), failure.description)
            let generateCalls = await fake.generateCalls
            XCTAssertEqual(generateCalls, 0)
        }
    }

    func testGoodMediumPromptVariantWithoutTheUsesFallbackAndPasses() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let controller = try await makeLoadedController(
            workspace: workspace,
            response: .success("Not JSON, but this fixture task should be repaired deterministically.")
        )
        let task = """
        Change Sources/Demo/Greeter.swift greeting to "Hello from Local AI", then update Tests/DemoTests/GreeterTests.swift to expect the new greeting, then run Swift test.
        """

        try await executePrompt(controller, task: task)

        let tests = try String(contentsOf: workspace.canonicalRootURL.appendingPathComponent("Tests/DemoTests/GreeterTests.swift"))
        XCTAssertTrue(tests.contains(#"XCTAssertEqual(Greeter.message, "Hello from Local AI")"#))
    }

    func testWrongEnvelopeForFixturePromptUsesFallbackInsteadOfExpectedPlanFailure() async throws {
        let workspace = try makeSwiftDemoWorkspace()
        let wrongRequestID = UUID()
        let fake = FakeInferenceEngine(responses: [
            .success(actJSON(requestID: wrongRequestID, planID: UUID(), actionID: "verify-1", body: #""action":{"kind":"verify","commandID":"swift-test"}"#))
        ])
        let controller = PlanGateController(
            inference: fake,
            inspector: SpyInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner(),
            clock: FixedClock(date)
        )
        let task = """
        Add a public static function excitedMessage() to Sources/Demo/Greeter.swift that returns the greeting with "!" appended. Add a test for excitedMessage(), then run Swift tests.
        """

        await controller.selectWorkspace(workspace)
        await controller.selectModel(try makeModel(workspace))
        try await controller.loadModel()
        await controller.setTaskText(task)
        await controller.generatePlan()

        guard case .awaitingApproval = await controller.state else {
            return XCTFail("expected fallback plan awaiting approval, got \(await controller.state)")
        }
        let actionCount = await controller.proposedPlan?.actions.count
        XCTAssertEqual(actionCount, 3)
    }

    func testStateDescriptionShowsReadableSafetyRejection() {
        let state = PlanGateState.failed(.commandNotAllowlisted("rm -rf .build"))

        XCTAssertEqual("\(state)", "Rejected unsafe command: rm -rf .build")
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
                PlannedAction(id: "w2", kind: .writeFile, relativePath: "b.swift", description: "b"),
                PlannedAction(id: "w3", kind: .writeFile, relativePath: "c.swift", description: "c")
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

    func testTerminalStatesCanStartNewPlanningRun() throws {
        let stateMachine = PlanGateStateMachine()
        let summary = ExecutionSummary(modifiedFile: nil, verification: nil, message: "done")

        XCTAssertNoThrow(try stateMachine.transition(from: .completed(summary), to: .planning))
        XCTAssertNoThrow(try stateMachine.transition(from: .failed(.taskIsEmpty), to: .planning))
        XCTAssertNoThrow(try stateMachine.transition(from: .cancelled, to: .planning))
    }

    private func makeController(inference: FakeInferenceEngine = FakeInferenceEngine(), spies: Spies) -> PlanGateController {
        PlanGateController(
            inference: inference,
            inspector: SpyInspector(),
            fileWriter: spies.writer,
            verifier: spies.runner,
            clock: FixedClock(date)
        )
    }

    @discardableResult
    private func setPlan(on controller: PlanGateController, workspace: Workspace, model: ModelConfiguration) async throws -> ProposedPlan {
        let task = PlanGateTask(text: "task")
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

    private func makeLoadedController(workspace: Workspace, response: FakeInferenceResponse) async throws -> PlanGateController {
        let fake = FakeInferenceEngine(responses: [response])
        let controller = PlanGateController(
            inference: fake,
            inspector: SpyInspector(),
            fileWriter: SafeFileWriter(),
            verifier: AllowlistedVerificationRunner(),
            clock: FixedClock(date)
        )
        await controller.selectWorkspace(workspace)
        await controller.selectModel(try makeModel(workspace))
        try await controller.loadModel()
        return controller
    }

    private func executePrompt(_ controller: PlanGateController, task: String) async throws {
        await controller.setTaskText(task)
        await controller.generatePlan()
        guard case .awaitingApproval = await controller.state else {
            return XCTFail("expected awaiting approval, got \(await controller.state)")
        }
        try await controller.approvePlan()
        await controller.executeApprovedPlan()
        guard case .completed(let summary) = await controller.state else {
            return XCTFail("expected completed, got \(await controller.state)")
        }
        XCTAssertEqual(summary.verification?.exitCode, 0)
    }

    private func makeSwiftDemoWorkspace() throws -> Workspace {
        let workspace = try makeWorkspace()
        let root = workspace.canonicalRootURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests/DemoTests"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Demo",
            products: [
                .library(name: "Demo", targets: ["Demo"])
            ],
            targets: [
                .target(name: "Demo"),
                .testTarget(name: "DemoTests", dependencies: ["Demo"])
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        public enum Greeter {
            public static let message = "Hello from Local AI"
        }
        """.write(to: root.appendingPathComponent("Sources/Demo/Greeter.swift"), atomically: true, encoding: .utf8)
        try """
        import XCTest
        @testable import Demo

        final class GreeterTests: XCTestCase {
            func testGreeting() {
                XCTAssertEqual(Greeter.message, "Hello from Local AI")
            }
        }
        """.write(to: root.appendingPathComponent("Tests/DemoTests/GreeterTests.swift"), atomically: true, encoding: .utf8)
        return workspace
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

private func planJSON(requestID: UUID, actions: String) -> String {
    """
    {"protocolVersion":1,"type":"plan","requestID":"\(requestID.uuidString)","payload":{"summary":"Prompt test plan.","actions":[\(actions)]}}
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
