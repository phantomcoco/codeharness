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
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                let values = try canonical.resourceValues(forKeys: [.fileSizeKey])
                let model = ModelConfiguration(url: url, canonicalPath: canonical.path, fileSizeBytes: Int64(values.fileSize ?? 0))
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

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        HSplitView {
            configurationColumn
                .frame(minWidth: 260, idealWidth: 320)
            taskColumn
                .frame(minWidth: 420, idealWidth: 520)
            activityColumn
                .frame(minWidth: 320, idealWidth: 380)
        }
        .frame(minWidth: 1100, minHeight: 720)
    }

    private var configurationColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local AI Coding Harness")
                    .font(.title2.bold())
                SectionHeader("Workspace")
                Button("Select Workspace", action: viewModel.selectWorkspace)
                Text(viewModel.workspacePath)
                    .font(.caption)
                    .textSelection(.enabled)

                SectionHeader("Model")
                Button("Select GGUF Model", action: viewModel.selectModel)
                Text(viewModel.modelPath)
                    .font(.caption)
                    .textSelection(.enabled)
                HStack {
                    Button("Load", action: viewModel.loadModel)
                    Button("Unload", action: viewModel.unloadModel)
                    Button("Smoke", action: viewModel.runSmokeTest)
                        .disabled(!viewModel.canSmokeTest)
                }
                Text(viewModel.modelState)
                    .font(.caption)
                    .textSelection(.enabled)
                if !viewModel.smokeOutput.isEmpty || !viewModel.smokeMetrics.isEmpty {
                    Text("Smoke Test")
                        .font(.headline)
                        .padding(.top, 6)
                    Text(viewModel.smokeMetrics)
                        .font(.caption.monospaced())
                    Text(viewModel.smokeOutput)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                SectionHeader("soul.md")
                Text(viewModel.guidanceStatus)
                    .font(.caption)
                HStack {
                    Button("Load File", action: viewModel.loadSoulFile)
                    Button("Apply Manual", action: viewModel.applyManualGuidance)
                    Button("Clear", action: viewModel.clearSoulGuidance)
                }
                TextEditor(text: $viewModel.manualGuidance)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
            }
            .padding()
        }
    }

    private var taskColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("State")
                    .font(.headline)
                StatusBadge(text: "\(viewModel.state)")
                Spacer()
                if viewModel.isBusy {
                    Button("Cancel", action: viewModel.cancelCurrentOperation)
                }
            }

            TextEditor(text: $viewModel.taskText)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .border(.separator)

            HStack {
                Button("Generate Plan", action: viewModel.generatePlan)
                    .disabled(!viewModel.canGenerate)
                Button("Approve", action: viewModel.approvePlan)
                    .disabled(!viewModel.canApprove)
                Button("Reject", action: viewModel.rejectPlan)
                    .disabled(!viewModel.canApprove)
                Button("Execute", action: viewModel.executeApprovedPlan)
                    .disabled(!viewModel.canExecute)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Divider()
            Text("Displayed Plan")
                .font(.headline)
            Text(viewModel.planSummary.isEmpty ? "No plan generated." : viewModel.planSummary)
                .textSelection(.enabled)
            if !viewModel.fingerprintPreview.isEmpty {
                Text("Fingerprint: \(viewModel.fingerprintPreview)")
                    .font(.caption.monospaced())
            }
            Text(viewModel.approvalStatus)
                .font(.caption)
            List(viewModel.actions) { action in
                VStack(alignment: .leading) {
                    Text(action.description)
                        .font(.body)
                    Text(action.kind == .writeFile ? "writeFile: \(action.relativePath ?? "")" : "verify: \(action.commandID ?? "")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var activityColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity")
                .font(.headline)
            List(viewModel.activity) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.kind.rawValue)
                        .font(.caption.bold())
                    Text(event.message)
                        .font(.caption)
                }
            }
            if !viewModel.outcome.isEmpty {
                Divider()
                Text("Outcome")
                    .font(.headline)
                Text(viewModel.outcome)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.top, 6)
    }
}

struct StatusBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    ContentView()
}
