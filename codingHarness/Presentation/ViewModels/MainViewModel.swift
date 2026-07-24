import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class MainViewModel: ObservableObject {
    @Published private(set) var state: HarnessState = .idle
    @Published private(set) var workspacePath = "No workspace selected"
    @Published private(set) var modelPath = "No model selected"
    @Published private(set) var modelState = "Unloaded"
    @Published private(set) var smokeOutput = ""
    @Published private(set) var smokeMetrics = ""
    @Published var taskText = ""
    @Published var manualGuidance = ""
    @Published private(set) var guidanceStatus = "No guidance"
    @Published private(set) var planSummary = ""
    @Published private(set) var actions: [PlannedAction] = []
    @Published private(set) var approvalStatus = "Not approved"
    @Published private(set) var fingerprintPreview = ""
    @Published private(set) var activity: [ActivityEvent] = []
    @Published private(set) var outcome = ""
    @Published private(set) var errorMessage: String?

    private let controller: CodingHarnessController
    private let validator = WorkspaceSecurityValidator()
    private let defaultModelFileName = "gemma-3-1b-it-Q4_K_M.gguf"

    init(container: AppContainer = .production()) {
        controller = container.controller
        Task { await refresh() }
    }

    var canGenerate: Bool {
        !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !workspacePath.hasPrefix("No ") &&
            !modelPath.hasPrefix("No ") &&
            !isBusy
    }

    var canSmokeTest: Bool {
        if case .loaded = currentInferenceState { return !isBusy }
        return false
    }

    private var currentInferenceState: InferenceState = .unloaded

    var canApprove: Bool {
        if case .awaitingApproval = state { return true }
        return false
    }

    var canExecute: Bool {
        canApprove && approvalStatus.hasPrefix("Approved")
    }

    var isBusy: Bool {
        if case .planning = state { return true }
        if case .executing = state { return true }
        return false
    }

    func selectWorkspace() {
        HarnessTrace.log("ui.selectWorkspace.clicked")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let workspace = try validator.canonicalWorkspace(from: url)
                await controller.selectWorkspace(workspace)
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func loadDefaultWorkspace() {
        HarnessTrace.log("ui.loadDefaultWorkspace.clicked")
        Task {
            do {
                let workspace = try validator.canonicalWorkspace(from: defaultWorkspaceURL())
                await controller.selectWorkspace(workspace)
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func selectModel() {
        HarnessTrace.log("ui.selectModel.clicked")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "gguf")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let model = try modelConfiguration(from: url)
                await controller.selectModel(model)
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func loadDefaultModel() {
        HarnessTrace.log("ui.loadDefaultModel.clicked")
        Task {
            do {
                let model = try modelConfiguration(from: defaultModelURL())
                await controller.selectModel(model)
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func loadModel() {
        HarnessTrace.log("ui.loadModel.clicked")
        Task {
            do {
                try await controller.loadModel()
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func unloadModel() {
        HarnessTrace.log("ui.unloadModel.clicked")
        Task {
            await controller.unloadModel()
            await refresh()
        }
    }

    func runSmokeTest() {
        HarnessTrace.log("ui.smoke.clicked")
        Task {
            do {
                let result = try await controller.runNativeSmokeTest()
                smokeOutput = result.rawOutput
                smokeMetrics = """
                \(result.completed ? "completed" : "output mismatch")
                load: \(format(seconds: result.loadDuration))
                prompt eval: \(format(seconds: result.promptEvaluationDuration))
                generation: \(format(seconds: result.generationDuration))
                tokens: \(result.generatedTokenCount)
                speed: \(String(format: "%.2f", result.tokensPerSecond)) tok/s
                """
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func loadSoulFile() {
        HarnessTrace.log("ui.loadSoulFile.clicked")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                await controller.setGuidance(BehaviorGuidance(source: .file(url), content: content))
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func applyManualGuidance() {
        HarnessTrace.log("ui.applyManualGuidance.clicked chars=\(manualGuidance.count)")
        Task {
            await controller.setGuidance(BehaviorGuidance(source: .manual, content: manualGuidance))
            await refresh()
        }
    }

    func clearSoulGuidance() {
        HarnessTrace.log("ui.clearSoulGuidance.clicked")
        manualGuidance = ""
        Task {
            await controller.setGuidance(.none)
            await refresh()
        }
    }

    func generatePlan() {
        HarnessTrace.log("ui.generatePlan.clicked taskChars=\(taskText.count)")
        Task {
            await controller.setTaskText(taskText)
            await controller.generatePlan()
            await refresh()
        }
    }

    func approvePlan() {
        HarnessTrace.log("ui.approvePlan.clicked")
        Task {
            do {
                try await controller.approvePlan()
                await refresh()
            } catch {
                await setError(error)
            }
        }
    }

    func rejectPlan() {
        HarnessTrace.log("ui.rejectPlan.clicked")
        Task {
            await controller.rejectPlan()
            await refresh()
        }
    }

    func executeApprovedPlan() {
        HarnessTrace.log("ui.executeApprovedPlan.clicked")
        Task {
            await controller.executeApprovedPlan()
            await refresh()
        }
    }

    func cancelCurrentOperation() {
        HarnessTrace.log("ui.cancel.clicked")
        Task {
            await controller.cancelCurrentOperation()
            await refresh()
        }
    }

    private func refresh() async {
        HarnessTrace.log("ui.refresh.start")
        state = await controller.state
        if let workspace = await controller.workspace {
            workspacePath = workspace.canonicalRootURL.path
        }
        if let model = await controller.model {
            modelPath = """
            \(model.url.lastPathComponent)
            \(model.canonicalPath)
            \(ByteCountFormatter.string(fromByteCount: model.fileSizeBytes, countStyle: .file))
            ctx \(model.contextSize), max \(model.maximumOutputTokens), threads \(model.threadCount)/\(model.batchThreadCount), gpu layers \(model.gpuLayerCount)
            """
        }
        let inferenceState = await controller.inferenceState()
        currentInferenceState = inferenceState
        modelState = format(inferenceState: inferenceState)
        let guidance = await controller.guidance
        guidanceStatus = guidance.content.isEmpty ? "No guidance" : "Guidance present: \(guidance.preview)"
        if let plan = await controller.proposedPlan {
            planSummary = plan.summary
            actions = plan.actions
            fingerprintPreview = (try? await controller.fingerprintPreview()) ?? ""
        } else {
            planSummary = ""
            actions = []
            fingerprintPreview = ""
        }
        approvalStatus = await controller.approval == nil ? "Not approved" : "Approved for current fingerprint"
        activity = await controller.events
        if case .completed(let summary) = state {
            outcome = summary.message
        } else if case .failed(let failure) = state {
            outcome = failure.description
        } else {
            outcome = ""
        }
        HarnessTrace.log("ui.refresh.done state=\(state) actions=\(actions.count) events=\(activity.count)")
    }

    private func setError(_ error: Error) async {
        HarnessTrace.log("ui.error \(error)")
        if let appFailure = error as? AppFailure {
            errorMessage = appFailure.description
        } else if let llamaFailure = error as? LlamaInferenceError {
            errorMessage = llamaFailure.description
        } else {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    private func defaultWorkspaceURL() throws -> URL {
        let root = try projectRootURL()
        let url = root.appendingPathComponent("FixtureWorkspace", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppFailure.invalidPath("Default workspace not found: \(url.path)")
        }
        return url
    }

    private func defaultModelURL() throws -> URL {
        let root = try projectRootURL()
        let url = root
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(defaultModelFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppFailure.invalidPath("Default model not found: \(url.path)")
        }
        return url
    }

    private func projectRootURL() throws -> URL {
        var sourceURL = URL(fileURLWithPath: #filePath)
        sourceURL.deleteLastPathComponent()
        var candidate = sourceURL
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("FixtureWorkspace", isDirectory: true).path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("codingHarness.xcodeproj", isDirectory: true).path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        var url = Bundle.main.bundleURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("FixtureWorkspace", isDirectory: true).path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("codingHarness.xcodeproj", isDirectory: true).path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw AppFailure.invalidPath("Project root not found from app bundle.")
    }

    private func modelConfiguration(from url: URL) throws -> ModelConfiguration {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try canonical.resourceValues(forKeys: [.fileSizeKey])
        return ModelConfiguration(url: url, canonicalPath: canonical.path, fileSizeBytes: Int64(values.fileSize ?? 0))
    }

    private func format(inferenceState: InferenceState) -> String {
        switch inferenceState {
        case .unloaded:
            return "Unloaded"
        case .loading:
            return "Loading"
        case .generating:
            return "Generating"
        case .failed(let message):
            return "Failed: \(message)"
        case .loaded(let metadata):
            return """
            Loaded
            \(metadata.description)
            context: \(metadata.contextSize)
            threads: \(metadata.threadCount)/\(metadata.batchThreadCount)
            GPU layers: \(metadata.gpuLayerCount)
            backend: \(metadata.backendDescription)
            load: \(format(seconds: metadata.loadDuration))
            size: \(ByteCountFormatter.string(fromByteCount: Int64(metadata.sizeBytes), countStyle: .file))
            params: \(metadata.parameterCount)
            """
        }
    }

    private func format(seconds: TimeInterval) -> String {
        String(format: "%.3fs", seconds)
    }
}
