# Local AI Coding Harness

Native macOS app for a host-owned `Plan -> Approval -> Execute` coding workflow. User selects a workspace, selects a local `.gguf` Gemma-compatible model, optionally supplies `soul.md`, generates a structured plan, approves the exact displayed plan, then executes a bounded plan of validated file replacement actions and one verification command.

## Requirements

- macOS 14 or later
- Xcode 26.2 used during implementation
- Swift 5.9 package tests, Swift 5 app settings preserved where possible
- Local Gemma GGUF model, for example Gemma 3 1B Instruct GGUF

## Architecture

Code is split by responsibility in `codingHarness/Core/HarnessCore.swift` and presentation in `codingHarness/ContentView.swift`.

- Presentation: SwiftUI `ContentView` and `MainViewModel`
- Application: `CodingHarnessController`, `AppContainer`, `HarnessStateMachine`
- Domain: state, plans, actions, approval records, activity, errors, protocol envelopes
- Infrastructure: workspace inspector, path validator, file writer, command runner, fake and llama inference engines

MVVM-C is represented by `MainViewModel` sending user intents into `CodingHarnessController`; views render only state. Dependencies are protocol-based: `InferenceEngine`, `WorkspaceInspecting`, `FileWriting`, `VerificationRunning`, and `Clock`.

## State Machine

`HarnessState` is a strongly typed enum:

`idle -> planning -> awaitingApproval -> executing -> completed | failed | cancelled`

`HarnessStateMachine` rejects invalid transitions. `awaitingApproval -> executing` requires an approval record matching the current plan fingerprint.

## llama.cpp Integration

Repository:

`https://github.com/ggml-org/llama.cpp`

Integration:

Swift Package Manager local wrapper at `Packages/LlamaBinary`, using the official llama.cpp b9999 XCFramework binary artifact.

Linked package product:

`LlamaBinary`

Imported Swift module:

`llama`

Artifact:

`https://github.com/ggml-org/llama.cpp/releases/download/b9999/llama-b9999-xcframework.zip`

Checksum:

`edc986f1e646d69fc331074a57b909082e9172c0bb09eef06ade6afdf4496c5a`

Date tested:

2026-07-24

Xcode version:

26.2

macOS deployment target:

14.0

Production uses `LlamaInferenceEngine`, an actor. The macOS application target links package product `LlamaBinary`, and `NativeLlamaInferenceEngine` imports module `llama` directly. The fallback path that reported `"llama Swift package is not linked"` was removed from production code.

Native APIs used from the b9999 XCFramework:

- `llama_backend_init`
- `llama_model_default_params`
- `llama_model_load_from_file`
- `llama_context_default_params`
- `llama_init_from_model`
- `llama_model_get_vocab`
- `llama_tokenize`
- `llama_batch_init`
- `llama_decode`
- `llama_model_chat_template`
- `llama_chat_apply_template`
- `llama_sampler_chain_default_params`
- `llama_sampler_chain_init`
- `llama_sampler_chain_add`
- `llama_sampler_init_temp`
- `llama_sampler_init_dist`
- `llama_sampler_sample`
- `llama_sampler_accept`
- `llama_vocab_is_eog`
- `llama_token_to_piece`
- `llama_get_memory`
- `llama_memory_clear`
- `llama_free`
- `llama_model_free`
- `llama_sampler_free`
- `llama_backend_free`

Metal acceleration is requested on Apple Silicon by setting `n_gpu_layers` to the selected model configuration default (`999`). The official XCFramework includes Metal support and is embedded into the macOS app bundle by Xcode.

## Reference Model

Model family:

Gemma 3 1B Instruct

GGUF repository:

`ggml-org/gemma-3-1b-it-GGUF`

Recommended file:

`gemma-3-1b-it-Q4_K_M.gguf`

The model is not bundled. Download the GGUF separately, then select it through the app. Tests never load model weights. Other compatible Gemma GGUF variants may be selected. The application does not use a local server, HTTP inference, Ollama, LM Studio, Jan, LocalAI, Python bindings, or llama CLI subprocesses.

## Model Flow

Select a `.gguf` file, inspect canonical path, size, context size, output-token cap, thread count, and GPU-layer request, then press Load. The model is owned by the native actor. `llama.cpp` verifies the file during load; extension alone is not treated as proof. Tests use `FakeInferenceEngine` and never load weights.

## Safety

- No write or command before approval
- Approval is SHA-256 over sorted JSON for the exact `ProposedPlan`
- Changing workspace, model, task, guidance, or plan invalidates approval
- Model paths are untrusted
- Rejects absolute paths, Windows paths, `..`, null bytes, `~`, file URLs, and symlink escapes
- Writes are bounded to a narrow approved plan, capped at two file replacements for the fixture workflow, limited to 1 MB each, and atomically replace complete files
- Only command ID `swift-test` is allowed, mapped by host to `/usr/bin/swift test`
- No shell, no pipes, no model-provided executable or arguments
- Verification output is bounded to 50 KB, timeout is 60 seconds
- Cancellation calls inference and process cancellation hooks

## soul.md

`soul.md` is optional preference guidance for identity, tone, planning style, coding preferences, explanation style, and execution preferences. It is never a security boundary and cannot approve plans, expand access, add commands, or disable host validation.

## Demo Fixture

Fixture workspace lives at `FixtureWorkspace`.

Example task:

`Change the greeting in Sources/Demo/Greeter.swift from "Hello" to "Hello from Local AI", then run Swift tests.`

The fixture test intentionally fails before approved execution and passes after `Greeter.swift` is replaced.

## Quick Local Test

Run the harness unit tests from the repository root:

```sh
cd codeharness
swift test
```

Run the demo fixture only after the app has executed the sample plan against `FixtureWorkspace`:

```sh
cd codeharness/FixtureWorkspace
swift test
```

If you selected another folder, the app writes there instead. The output path is shown in the right Activity panel under `fileWrite`, for example `Wrote 78 bytes to Sources/Demo/Greeter.swift`.

## Run

Open `codingHarness.xcodeproj`, confirm local package `Packages/LlamaBinary` is resolved, confirm product `LlamaBinary` is linked to the `codingHarness` macOS target, then run scheme `codingHarness`.

Run deterministic tests:

```sh
swift test
```

Build app:

```sh
xcodebuild -project codingHarness.xcodeproj -scheme codingHarness -destination 'platform=macOS' build
```

## Manual Native Smoke Test

1. Download `gemma-3-1b-it-Q4_K_M.gguf` separately from `ggml-org/gemma-3-1b-it-GGUF`.
2. Launch the app.
3. Select the `.gguf`.
4. Click Load.
5. Confirm loaded model metadata, context size, thread config, GPU-layer request, and backend label.
6. Click Smoke.
7. Confirm smoke status says `completed`. The raw output may be plain JSON or fenced JSON, as long as the parsed payload matches:

```json
{"type":"stop","reason":"native inference is working"}
```

The smoke test only runs inference. It does not write files, run commands, approve plans, or bypass the `Plan -> Approval -> Execute` state machine.

## Verification Steps

1. Open the project in Xcode.
2. Confirm local package `Packages/LlamaBinary` is resolved.
3. Confirm product `LlamaBinary` is linked to the macOS target.
4. Build the app.
5. Download the reference GGUF separately.
6. Launch the app.
7. Select the `.gguf`.
8. Click Load.
9. Confirm loaded model metadata.
10. Run the native inference smoke test.
11. Generate a coding plan.
12. Review and approve before execution.

## App Sandbox

App Sandbox is disabled for this prototype so the native app can load a user-selected local GGUF and operate on the selected workspace without a separate model service. The security boundary is the host-owned controller: the user selects the workspace, model-generated paths are canonicalized and validated before any write, and model text is never passed to a shell.

## Known Limitations

- Complete-file replacement only; true patch application is not implemented.
- Real execution currently writes deterministic host-generated content for the initial vertical slice rather than asking the model for act content during execution.
- Real Gemma smoke testing requires a local GGUF file; normal tests intentionally do not load weights.
- Model weights and build artifacts are intentionally ignored by git.

## Implementation Time

Approximate actual implementation time: one focused Codex session.
