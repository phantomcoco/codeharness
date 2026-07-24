import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

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
                Text("PlanGate")
                    .font(.title2.bold())
                SectionHeader("Workspace")
                HStack {
                    Button("Select Workspace", action: viewModel.selectWorkspace)
                    Button("Load Default", action: viewModel.loadDefaultWorkspace)
                }
                Text(viewModel.workspacePath)
                    .font(.caption)
                    .textSelection(.enabled)

                SectionHeader("Model")
                HStack {
                    Button("Select GGUF Model", action: viewModel.selectModel)
                    Button("Load Default", action: viewModel.loadDefaultModel)
                }
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

#Preview {
    ContentView()
}
