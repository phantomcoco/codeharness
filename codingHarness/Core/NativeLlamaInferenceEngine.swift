#if canImport(llama)
import Foundation
import llama

private final class LlamaCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

actor NativeLlamaInferenceEngine: InferenceEngine {
    private var inferenceState: InferenceState = .unloaded
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var loadedMetadata: ModelMetadata?
    private var backendInitialized = false
    private let cancellation = LlamaCancellationBox()

    var state: InferenceState { inferenceState }

    func loadModel(configuration: ModelConfiguration) async throws {
        HarnessTrace.log("nativeLlama.loadModel.start file=\(configuration.url.lastPathComponent) bytes=\(configuration.fileSizeBytes)")
        guard configuration.url.isFileURL else {
            inferenceState = .failed(LlamaInferenceError.invalidModelURL.description)
            throw LlamaInferenceError.invalidModelURL
        }
        guard FileManager.default.fileExists(atPath: configuration.canonicalPath) else {
            inferenceState = .failed(LlamaInferenceError.modelFileMissing.description)
            throw LlamaInferenceError.modelFileMissing
        }
        guard configuration.url.pathExtension.lowercased() == "gguf" else {
            inferenceState = .failed(LlamaInferenceError.unsupportedModel.description)
            throw LlamaInferenceError.unsupportedModel
        }

        await unloadModel()
        inferenceState = .loading
        let started = Date()
        llama_backend_init()
        backendInitialized = true

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = configuration.gpuLayerCount
        #endif

        guard let loadedModel = configuration.canonicalPath.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            inferenceState = .failed(LlamaInferenceError.modelLoadFailed.description)
            HarnessTrace.log("nativeLlama.loadModel.failed reason=modelLoad")
            throw LlamaInferenceError.modelLoadFailed
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = configuration.contextSize
        contextParams.n_batch = configuration.contextSize
        contextParams.n_threads = configuration.threadCount
        contextParams.n_threads_batch = configuration.batchThreadCount
        contextParams.offload_kqv = configuration.gpuLayerCount > 0

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            inferenceState = .failed(LlamaInferenceError.contextCreationFailed.description)
            HarnessTrace.log("nativeLlama.loadModel.failed reason=contextInit")
            throw LlamaInferenceError.contextCreationFailed
        }
        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            inferenceState = .failed(LlamaInferenceError.unsupportedModel.description)
            HarnessTrace.log("nativeLlama.loadModel.failed reason=vocab")
            throw LlamaInferenceError.unsupportedModel
        }

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_temp(configuration.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(configuration.seed))

        model = loadedModel
        context = loadedContext
        vocab = loadedVocab
        sampler = chain
        let backend = configuration.gpuLayerCount > 0 ? "Metal requested via GGML_USE_METAL + n_gpu_layers=\(configuration.gpuLayerCount)" : "CPU"
        let metadata = ModelMetadata(
            identifier: configuration.identifier,
            description: modelDescription(loadedModel),
            contextSize: llama_n_ctx(loadedContext),
            threadCount: configuration.threadCount,
            batchThreadCount: configuration.batchThreadCount,
            gpuLayerCount: configuration.gpuLayerCount,
            backendDescription: backend,
            loadDuration: Date().timeIntervalSince(started),
            sizeBytes: llama_model_size(loadedModel),
            parameterCount: llama_model_n_params(loadedModel)
        )
        loadedMetadata = metadata
        inferenceState = .loaded(metadata)
        HarnessTrace.log("nativeLlama.loadModel.done threads=\(configuration.threadCount) gpuLayers=\(configuration.gpuLayerCount)")
    }

    nonisolated func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        HarnessTrace.log("nativeLlama.generate.start requestID=\(request.id) maxTokens=\(request.maxTokens)")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.generate(request: request, continuation: continuation)
                } catch LlamaInferenceError.cancelled {
                    continuation.yield(.cancelled)
                    continuation.finish(throwing: AppFailure.generationCancelled)
                } catch {
                    HarnessTrace.log("nativeLlama.generate.failed requestID=\(request.id) error=\(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.cancelGeneration() }
            }
        }
    }

    nonisolated func cancelGeneration() async {
        HarnessTrace.log("nativeLlama.cancelGeneration")
        cancellation.cancel()
    }

    func unloadModel() async {
        HarnessTrace.log("nativeLlama.unloadModel.start hasModel=\(model != nil)")
        cancellation.cancel()
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
        vocab = nil
        loadedMetadata = nil
        inferenceState = .unloaded
        if backendInitialized {
            llama_backend_free()
            backendInitialized = false
        }
        HarnessTrace.log("nativeLlama.unloadModel.done")
    }

    private func generate(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws {
        HarnessTrace.log("nativeLlama.generateText.start requestID=\(request.id) messages=\(request.messages.count)")
        guard let model, let context, let vocab, let sampler else { throw LlamaInferenceError.modelNotLoaded }
        guard case .loaded = inferenceState else { throw LlamaInferenceError.generationAlreadyRunning }
        guard let loadedMetadata else { throw LlamaInferenceError.modelNotLoaded }

        inferenceState = .generating
        cancellation.reset()
        defer {
            if case .generating = inferenceState {
                inferenceState = .loaded(loadedMetadata)
            }
        }

        continuation.yield(.started)
        let prompt = try formatChat(messages: request.messages, model: model)
        let promptTokens = try tokenize(prompt, vocab: vocab, addBOS: true)
        HarnessTrace.log("nativeLlama.generateText.tokenized tokens=\(promptTokens.count)")
        guard UInt32(promptTokens.count + request.maxTokens) <= llama_n_ctx(context) else {
            throw LlamaInferenceError.promptTooLarge(promptTokens: promptTokens.count, contextSize: llama_n_ctx(context))
        }
        try checkCancellation()
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        var batch = llama_batch_init(Int32(max(promptTokens.count, 1)), 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(promptTokens.count)
        for (index, token) in promptTokens.enumerated() {
            add(token: token, position: Int32(index), logits: false, to: &batch, at: index)
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        guard llama_decode(context, batch) == 0 else { throw LlamaInferenceError.promptDecodeFailed }
        continuation.yield(.promptEvaluated)
        HarnessTrace.log("nativeLlama.generateText.promptDecoded tokens=\(promptTokens.count)")

        var output = ""
        var utf8Buffer: [CChar] = []
        var position = batch.n_tokens
        var decodedTokens = 0

        for _ in 0..<request.maxTokens {
            try checkCancellation()
            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            llama_sampler_accept(sampler, token)
            if llama_vocab_is_eog(vocab, token) { break }
            if let piece = try tokenToPiece(token, vocab: vocab, buffer: &utf8Buffer), !piece.isEmpty {
                output += piece
                continuation.yield(.token(piece))
            }

            batch.n_tokens = 1
            add(token: token, position: position, logits: true, to: &batch, at: 0)
            position += 1
            guard llama_decode(context, batch) == 0 else { throw LlamaInferenceError.tokenDecodeFailed }
            decodedTokens += 1
        }

        HarnessTrace.log("nativeLlama.generateText.done decodedTokens=\(decodedTokens) outputChars=\(output.count)")
        continuation.yield(.completed(output))
        continuation.finish()
    }

    private func checkCancellation() throws {
        if cancellation.isCancelled || Task.isCancelled {
            throw LlamaInferenceError.cancelled
        }
    }

    private func add(token: llama_token, position: llama_pos, logits: Bool, to batch: inout llama_batch, at index: Int) {
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]?[0] = 0
        batch.logits[index] = logits ? 1 : 0
    }

    private func tokenize(_ text: String, vocab: OpaquePointer, addBOS: Bool) throws -> [llama_token] {
        var capacity = max(8, text.utf8.count + (addBOS ? 1 : 0) + 1)
        var tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
        defer { tokens.deallocate() }
        var tokenCount = text.withCString {
            llama_tokenize(vocab, $0, Int32(text.utf8.count), tokens, Int32(capacity), addBOS, true)
        }
        if tokenCount < 0 {
            capacity = Int(-tokenCount)
            tokens.deallocate()
            tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
            tokenCount = text.withCString {
                llama_tokenize(vocab, $0, Int32(text.utf8.count), tokens, Int32(capacity), addBOS, true)
            }
        }
        guard tokenCount > 0 else { throw LlamaInferenceError.tokenizationFailed }
        return (0..<Int(tokenCount)).map { tokens[$0] }
    }

    private func tokenToPiece(_ token: llama_token, vocab: OpaquePointer, buffer: inout [CChar]) throws -> String? {
        var result = [CChar](repeating: 0, count: 8)
        var count = llama_token_to_piece(vocab, token, &result, Int32(result.count), 0, false)
        if count < 0 {
            result = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &result, Int32(result.count), 0, false)
        }
        guard count >= 0 else { throw LlamaInferenceError.tokenDecodeFailed }
        result.removeLast(result.count - Int(count))
        buffer.append(contentsOf: result)
        let data = Data(buffer.map { UInt8(bitPattern: $0) })
        guard let string = String(data: data, encoding: .utf8) else {
            if buffer.count > 4 { throw LlamaInferenceError.tokenDecodeFailed }
            return nil
        }
        buffer.removeAll()
        return string
    }

    private func formatChat(messages: [InferenceMessage], model: OpaquePointer) throws -> String {
        guard !messages.isEmpty else { throw LlamaInferenceError.chatTemplateFormattingFailed }
        let roles = messages.map { strdup($0.role.rawValue) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        guard roles.allSatisfy({ $0 != nil }), contents.allSatisfy({ $0 != nil }) else {
            throw LlamaInferenceError.chatTemplateFormattingFailed
        }
        var chat = messages.indices.map {
            llama_chat_message(role: UnsafePointer(roles[$0]), content: UnsafePointer(contents[$0]))
        }
        var capacity = max(1024, messages.reduce(0) { $0 + $1.content.utf8.count } * 3)
        var buffer = [CChar](repeating: 0, count: capacity)
        var written = applyTemplate(model: model, chat: &chat, buffer: &buffer)
        if written < 0 { throw LlamaInferenceError.chatTemplateUnavailable }
        if written >= capacity {
            capacity = Int(written) + 1
            buffer = [CChar](repeating: 0, count: capacity)
            written = applyTemplate(model: model, chat: &chat, buffer: &buffer)
        }
        guard written >= 0, written < capacity else { throw LlamaInferenceError.chatTemplateFormattingFailed }
        let data = Data(buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) })
        guard let prompt = String(data: data, encoding: .utf8), !prompt.isEmpty else {
            throw LlamaInferenceError.chatTemplateFormattingFailed
        }
        return prompt
    }

    private func applyTemplate(model: OpaquePointer, chat: inout [llama_chat_message], buffer: inout [CChar]) -> Int32 {
        guard let template = llama_model_chat_template(model, nil) else { return -1 }
        return chat.withUnsafeBufferPointer { chatPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                llama_chat_apply_template(
                    template,
                    chatPointer.baseAddress,
                    chat.count,
                    true,
                    bufferPointer.baseAddress,
                    Int32(bufferPointer.count)
                )
            }
        }
    }

    private func modelDescription(_ model: OpaquePointer) -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: 512)
        _ = llama_model_desc(model, buffer, 512)
        return String(cString: buffer)
    }
}
#endif
