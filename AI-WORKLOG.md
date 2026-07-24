# AI Worklog

- AI assistance used to inspect the starter Xcode project, read the provided requirements, inspect `llama.cpp` tags/examples, and implement the local harness.
- Major decisions: keep host-owned state machine central, bind approval with sorted JSON SHA-256, keep file and command execution behind protocols, and use fake inference for deterministic tests.
- Created areas: domain models, structured message decoding, approval binding, workspace validation, safe file writer, command runner, fake/llama inference, SwiftUI view model/UI, fixture workspace, README, tests.
- Manual validation performed: inspected Xcode build settings and package state; inspected current upstream `llama.cpp`, official Swift examples, and current b9999 C API symbols.
- Completed native package integration: linked the official `ggml-org/llama.cpp` b9999 XCFramework through local SwiftPM wrapper `Packages/LlamaBinary`, product `LlamaBinary`, Swift module `llama`.
- Real Gemma model load probe passed with `/Users/swaraj/Desktop/gemma/gemma-3-1b-it-Q4_K_M.gguf`: llama.cpp reported `gemma3 1B Q4_K - Medium`, SPM vocab, Metal on Apple M2, and successful 4096-token context creation. Deterministic tests still use fake inference and load no weights.
- Added robust structured JSON extraction for model replies that include prose or fenced JSON, and semantic smoke parsing for fenced JSON output.
- App Sandbox now uses user-selected read/write access so approved writes can save into a workspace chosen with the macOS folder picker.
- Final verification passed with `swift test` and `xcodebuild -project codingHarness.xcodeproj -scheme codingHarness -destination 'platform=macOS' build`.
- Approximate time spent: one focused implementation session.
