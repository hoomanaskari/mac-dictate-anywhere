//
//  S1MiniPostProcessingService.swift
//  Dictate Anywhere
//
//  Dedicated local transcript normalization using S1-mini by Superwhisper.
//

import Foundation
import LlamaSwift
import os

enum S1MiniStyling: String, CaseIterable, Codable, Identifiable, Sendable {
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .casual: return "Casual"
        case .semiCasual: return "Semi-Casual"
        case .semiFormal: return "Semi-Formal"
        case .formal: return "Formal"
        }
    }
}

struct S1MiniAppStyling: Codable, Equatable, Sendable {
    var email: S1MiniStyling
    var workMessaging: S1MiniStyling
    var personalMessaging: S1MiniStyling
    var other: S1MiniStyling

    static let recommended = S1MiniAppStyling(
        email: .formal,
        workMessaging: .semiFormal,
        personalMessaging: .semiCasual,
        other: .semiFormal
    )

    static func uniform(_ styling: S1MiniStyling) -> Self {
        Self(
            email: styling,
            workMessaging: styling,
            personalMessaging: styling,
            other: styling
        )
    }

    func styling(for category: DictationContextCategory) -> S1MiniStyling {
        switch category {
        case .email: return email
        case .workMessaging: return workMessaging
        case .personalMessaging: return personalMessaging
        case .other: return other
        }
    }

    mutating func set(_ styling: S1MiniStyling, for category: DictationContextCategory) {
        switch category {
        case .email: email = styling
        case .workMessaging: workMessaging = styling
        case .personalMessaging: personalMessaging = styling
        case .other: other = styling
        }
    }
}

enum S1MiniStructure: String, CaseIterable, Codable, Identifiable, Sendable {
    case prose
    case lists

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum S1MiniContextSetting: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case general
    case email

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .general: return "General"
        case .email: return "Email"
        }
    }

    func resolved(for context: DictationPostProcessingContext?) -> String {
        switch self {
        case .automatic:
            return context?.category == .email ? "email" : "general"
        case .general, .email:
            return rawValue
        }
    }
}

enum S1MiniModelSpec {
    static let displayName = "S1-mini by Superwhisper"
    static let repository = "superwhisper/s1-mini-GGUF"
    static let revision = "ee2c0f56e56345f475749a44ff2893e21c3cb292"
    static let filename = "s1-mini-q4_k_m.gguf"
    nonisolated static let byteCount: Int64 = 484_219_808
    nonisolated static let sha256 = "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    nonisolated static let maximumTranscriptTokens = 1_000

    static let downloadURL = URL(
        string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)?download=true"
    )!

    static let licenseURL = URL(
        string: "https://huggingface.co/\(repository)/resolve/\(revision)/LICENSE"
    )!
}

nonisolated enum S1MiniPromptBuilder {
    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    static func controlLine(
        styling: S1MiniStyling,
        structure: S1MiniStructure,
        context: String
    ) -> String {
        "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context)]"
    }

    static func prompt(
        transcript: String,
        styling: S1MiniStyling,
        structure: S1MiniStructure,
        context: String
    ) -> String {
        let prompt = """
        <|im_start|>system
        \(systemPrompt)<|im_end|>
        <|im_start|>user
        \(controlLine(styling: styling, structure: structure, context: context))
        \(transcript)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
        // Swift strips the newline immediately before a multiline string's
        // closing delimiter. S1-mini requires two newlines after </think>.
        return prompt + "\n"
    }
}

enum S1MiniServiceError: LocalizedError {
    case modelNotDownloaded
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case transcriptTooLong(actual: Int, maximum: Int)
    case promptEvaluationFailed(Int32)
    case tokenEvaluationFailed(Int32)
    case outputLimitReached
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Download S1-mini before using local transcript cleanup."
        case .modelLoadFailed:
            return "S1-mini could not be loaded. Delete and download the model again."
        case .contextCreationFailed:
            return "S1-mini could not allocate its inference context."
        case .tokenizationFailed:
            return "S1-mini could not tokenize the transcript."
        case .transcriptTooLong(let actual, let maximum):
            return "S1-mini supports up to \(maximum) transcript tokens; this transcript has \(actual)."
        case .promptEvaluationFailed(let code):
            return "S1-mini could not evaluate the transcript (code \(code))."
        case .tokenEvaluationFailed(let code):
            return "S1-mini stopped while generating cleaned text (code \(code))."
        case .outputLimitReached:
            return "S1-mini reached its output limit before finishing cleanup."
        case .invalidOutput:
            return "S1-mini returned invalid text."
        }
    }
}

actor S1MiniInferenceEngine {
    static let shared = S1MiniInferenceEngine()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "S1MiniInference"
    )
    private var model: OpaquePointer?
    // generate() never suspends, so the actor owns exclusive use of both
    // pointers. Retain allocations, never a previous request's KV contents.
    private var inferenceContext: OpaquePointer?
    private var loadedModelPath: String?
    private var warmedModelPath: String?
    private var backendInitialized = false
    private var useInputDrafting = true

    deinit {
        if let inferenceContext {
            llama_free(inferenceContext)
        }
        if let model {
            llama_model_free(model)
        }
        if backendInitialized {
            llama_backend_free()
        }
    }

    func unload() {
        discardInferenceContext()
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        loadedModelPath = nil
        warmedModelPath = nil
    }

    func isPrepared(for modelURL: URL) -> Bool {
        model != nil && inferenceContext != nil
            && warmedModelPath == modelURL.standardizedFileURL.path
    }

    /// Exercise context creation, prompt evaluation and generation, not just
    /// weight loading. Retain the allocations but clear synthetic request data.
    func prewarm(from url: URL) throws {
        try Task.checkCancellation()
        let trace = PerfTrace.begin("cleanup.prewarm")
        defer { trace.end() }
        _ = try loadModelIfNeeded(from: url)
        guard warmedModelPath != loadedModelPath else { return }
        let text = "Hello."
        _ = try generate(
            prompt: S1MiniPromptBuilder.prompt(transcript: text, styling: .semiFormal,
                                               structure: .prose, context: "general"),
            transcript: text, styling: .semiFormal, modelURL: url
        )
    }

    func transcriptChunks(_ text: String, modelURL: URL) throws -> [S1MiniTranscriptChunk] {
        let model = try loadModelIfNeeded(from: modelURL)
        guard let vocabulary = llama_model_get_vocab(model) else {
            throw S1MiniServiceError.modelLoadFailed
        }
        return try S1MiniTranscriptChunker.chunks(text, maximumTokens: S1MiniModelSpec.maximumTranscriptTokens) {
            try tokenize($0, vocabulary: vocabulary, addSpecial: false, parseSpecial: false).count
        }
    }

    func generate(
        prompt: String,
        transcript: String,
        styling: S1MiniStyling,
        modelURL: URL,
        knownTranscriptTokenCount: Int? = nil
    ) throws -> String {
        let trace = PerfTrace.begin("cleanup.generate")
        defer { trace.end() }
        try Task.checkCancellation()
        let model = try loadModelIfNeeded(from: modelURL)
        guard let vocabulary = llama_model_get_vocab(model) else {
            throw S1MiniServiceError.modelLoadFailed
        }

        let (transcriptTokenCount, initialPromptTokens, transcriptTokens) = try tokenizeInputs(
            transcript: transcript,
            prompt: prompt,
            styling: styling,
            vocabulary: vocabulary,
            knownTranscriptTokenCount: knownTranscriptTokenCount
        )
        var promptTokens = initialPromptTokens
        let maximumOutputTokens = max(32, Int(ceil(Double(transcriptTokenCount) * 1.3)) + 32)
        trace.recordCounts([
            "input_tokens": transcriptTokenCount,
            "prompt_tokens": promptTokens.count
        ])
        try Task.checkCancellation()
        let context = try context(for: model)
        var completed = false
        defer {
            if completed {
                // Reset token positions AND erase the KV buffers. The next
                // request starts at position zero with no transcript history.
                llama_synchronize(context)
                llama_memory_clear(llama_get_memory(context), true)
            } else {
                // A cancelled/failed decode may leave scheduler or output
                // state incomplete. Recreate it rather than reuse that state.
                discardInferenceContext()
            }
        }

        let firstTokenTrace = PerfTrace.begin("cleanup.firstToken")
        defer { firstTokenTrace.end() }
        let promptEvalTrace = PerfTrace.begin("cleanup.prefillSchedule")
        let promptStatus = promptTokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(
                context,
                llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
            )
        }
        promptEvalTrace.end()
        guard promptStatus == 0 else {
            throw S1MiniServiceError.promptEvaluationFailed(promptStatus)
        }
        try Task.checkCancellation()

        guard let sampler = llama_sampler_init_greedy() else {
            throw S1MiniServiceError.invalidOutput
        }
        defer { llama_sampler_free(sampler) }

        let (output, outputTokenCount) = try sampleOutput(
            context: context,
            vocabulary: vocabulary,
            sampler: sampler,
            maximumOutputTokens: maximumOutputTokens, firstTokenTrace: firstTokenTrace,
            transcriptTokens: transcriptTokens.map(Int.init)
        )
        trace.recordCounts(["output_tokens": outputTokenCount, "output_bytes": output.count])

        let decoded = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info(
            "generate: promptTokens=\(promptTokens.count, privacy: .public), inputTokens=\(transcriptTokenCount, privacy: .public), outputChars=\(decoded.count, privacy: .public)"
        )
        try Task.checkCancellation()
        completed = true
        warmedModelPath = loadedModelPath
        return decoded
    }

    private func context(for model: OpaquePointer) throws -> OpaquePointer {
        if let inferenceContext { return inferenceContext }
        let trace = PerfTrace.begin("cleanup.contextCreate")
        defer { trace.end() }
        var parameters = llama_context_default_params()
        // Smaller contexts caused valid Qwen3/S1 inputs to emit EOS early.
        parameters.n_ctx = 4_096
        parameters.n_batch = 2_048
        parameters.n_ubatch = 512
        parameters.n_outputs_max = 17
        parameters.n_outputs_max_per_seq = 17
        #if arch(arm64)
        // Metal measurements favor FP16 KV; keep the CPU Q8 path on Intel.
        parameters.type_k = GGML_TYPE_F16
        parameters.type_v = GGML_TYPE_F16
        #else
        parameters.type_k = GGML_TYPE_Q8_0
        parameters.type_v = GGML_TYPE_Q8_0
        #endif
        let threadCount = S1MiniCPUConfiguration.threadCount
        parameters.n_threads = threadCount
        parameters.n_threads_batch = threadCount
        guard let context = llama_init_from_model(model, parameters) else {
            throw S1MiniServiceError.contextCreationFailed
        }
        inferenceContext = context
        return context
    }

    private func discardInferenceContext() {
        if let inferenceContext { llama_free(inferenceContext) }
        inferenceContext = nil
        warmedModelPath = nil
    }

    #if DEBUG || PIPELINE_BENCHMARK
    // Lifecycle tests compare independent requests and inspect cache clearing.
    func discardInferenceContextForTesting() { discardInferenceContext() }

    func configureInputDraftingForTesting(_ enabled: Bool) { useInputDrafting = enabled }

    func inferenceContextStateForTesting() -> (allocated: Bool, maximumPosition: Int32) {
        guard let inferenceContext else { return (false, -1) }
        return (true, llama_memory_seq_pos_max(llama_get_memory(inferenceContext), 0))
    }
    #endif

    /// Tokenizes the transcript (for the length guard) and the prompt.
    /// Traced separately so future work can distinguish tokenizer cost
    /// from context setup, prompt evaluation, and sampling.
    private func tokenizeInputs(
        transcript: String,
        prompt: String,
        styling: S1MiniStyling,
        vocabulary: OpaquePointer,
        knownTranscriptTokenCount: Int?
    ) throws -> (transcriptTokenCount: Int, promptTokens: [llama_token], transcriptTokens: [llama_token]) {
        let trace = PerfTrace.begin("cleanup.tokenize")
        defer { trace.end() }
        // A planned chunk carries its exact count from this GGUF tokenizer.
        // The complete prompt below is always tokenized across all boundaries.
        let transcriptTokens = try tokenize(
            transcript,
            vocabulary: vocabulary,
            addSpecial: false,
            parseSpecial: false
        )
        let transcriptTokenCount = knownTranscriptTokenCount ?? transcriptTokens.count
        guard transcriptTokenCount <= S1MiniModelSpec.maximumTranscriptTokens else {
            throw S1MiniServiceError.transcriptTooLong(
                actual: transcriptTokenCount,
                maximum: S1MiniModelSpec.maximumTranscriptTokens
            )
        }
        let promptTokens = try tokenize(
            prompt,
            vocabulary: vocabulary,
            addSpecial: false,
            parseSpecial: true
        )
        var draftTokens = transcriptTokens
        if useInputDrafting {
            let proposalText = S1MiniInputDraft.proposalSource(transcript, styling: styling)
            if proposalText != transcript {
                draftTokens = try tokenize(proposalText, vocabulary: vocabulary,
                    addSpecial: false, parseSpecial: false)
            }
        }
        return (transcriptTokenCount, promptTokens, draftTokens)
    }

    /// Runs the autoregressive sampling loop. Traced separately so future
    /// work can derive per-token timings from the existing token counts.
    private func sampleOutput(
        context: OpaquePointer,
        vocabulary: OpaquePointer,
        sampler: UnsafeMutablePointer<llama_sampler>,
        maximumOutputTokens: Int, firstTokenTrace: PerfInterval, transcriptTokens: [Int]
    ) throws -> (Data, Int) {
        let trace = PerfTrace.begin("cleanup.decode")
        defer { trace.end() }
        var output = Data()
        var outputTokenCount = 0
        var draft = S1MiniInputDraft(tokens: transcriptTokens)
        var nextToken = llama_sampler_sample(sampler, context, -1)
        var position = llama_memory_seq_pos_max(llama_get_memory(context), 0) + 1
        var batch = llama_batch_init(17, 0, 1)
        defer { llama_batch_free(batch) }
        while true {
            try Task.checkCancellation()
            let token = nextToken
            firstTokenTrace.end()
            if llama_vocab_is_eog(vocabulary, token) {
                trace.recordCounts(["output_tokens": outputTokenCount])
                return (output, outputTokenCount)
            }
            guard outputTokenCount < maximumOutputTokens else {
                trace.recordCounts(["output_tokens": outputTokenCount])
                throw S1MiniServiceError.outputLimitReached
            }
            outputTokenCount += 1
            output.append(try piece(for: token, vocabulary: vocabulary))
            draft.didEmit(Int(token))
            let proposals = useInputDrafting
                ? draft.propose(maximumTokens: min(16, maximumOutputTokens - outputTokenCount)) : []
            if proposals.isEmpty {
                var input = token
                let status = llama_decode(context, llama_batch_get_one(&input, 1))
                guard status == 0 else { throw S1MiniServiceError.tokenEvaluationFailed(status) }
                position += 1
                nextToken = llama_sampler_sample(sampler, context, -1)
                continue
            }
            batch.n_tokens = Int32(proposals.count + 1)
            for (index, value) in ([Int(token)] + proposals).enumerated() {
                batch.token[index] = llama_token(value)
                batch.pos[index] = position + Int32(index)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = 0
                batch.logits[index] = 1
            }
            let status = llama_decode(context, batch)
            guard status == 0 else { throw S1MiniServiceError.tokenEvaluationFailed(status) }
            var accepted = 0
            nextToken = llama_sampler_sample(sampler, context, 0)
            while accepted < proposals.count && Int(nextToken) == proposals[accepted] {
                try Task.checkCancellation()
                if llama_vocab_is_eog(vocabulary, nextToken) {
                    trace.recordCounts(["output_tokens": outputTokenCount])
                    return (output, outputTokenCount)
                }
                guard outputTokenCount < maximumOutputTokens else { throw S1MiniServiceError.outputLimitReached }
                output.append(try piece(for: nextToken, vocabulary: vocabulary))
                outputTokenCount += 1
                draft.didEmit(Int(nextToken))
                accepted += 1
                nextToken = llama_sampler_sample(sampler, context, Int32(accepted))
            }
            position += Int32(accepted + 1)
            if accepted < proposals.count {
                guard llama_memory_seq_rm(llama_get_memory(context), 0, position, -1) else {
                    throw S1MiniServiceError.invalidOutput
                }
            }
        }
    }

    /// Loads the cached model or the model at `url`.
    func loadModelIfNeeded(from url: URL) throws -> OpaquePointer {
        let trace = PerfTrace.begin("cleanup.modelLoad")
        defer { trace.end() }
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw S1MiniServiceError.modelNotDownloaded
        }
        if let model, loadedModelPath == path {
            return model
        }

        unload()
        if !backendInitialized {
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            backendInitialized = true
        }

        var parameters = llama_model_default_params()
#if arch(arm64)
        parameters.n_gpu_layers = -1
#else
        parameters.n_gpu_layers = 0
#endif
        parameters.check_tensors = true
        parameters.use_extra_bufts = true

        guard let loaded = llama_model_load_from_file(path, parameters) else {
            throw S1MiniServiceError.modelLoadFailed
        }
        model = loaded
        loadedModelPath = path
        return loaded
    }

    private func tokenize(
        _ text: String,
        vocabulary: OpaquePointer,
        addSpecial: Bool,
        parseSpecial: Bool
    ) throws -> [llama_token] {
        let byteCount = text.utf8.count
        var tokens = [llama_token](repeating: 0, count: max(32, byteCount + 8))
        var count = text.withCString { pointer in
            llama_tokenize(
                vocabulary,
                pointer,
                Int32(byteCount),
                &tokens,
                Int32(tokens.count),
                addSpecial,
                parseSpecial
            )
        }

        if count < 0, count != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString { pointer in
                llama_tokenize(
                    vocabulary,
                    pointer,
                    Int32(byteCount),
                    &tokens,
                    Int32(tokens.count),
                    addSpecial,
                    parseSpecial
                )
            }
        }
        guard count >= 0 else {
            throw S1MiniServiceError.tokenizationFailed
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token, vocabulary: OpaquePointer) throws -> Data {
        var buffer = [CChar](repeating: 0, count: 128)
        var count = llama_token_to_piece(
            vocabulary,
            token,
            &buffer,
            Int32(buffer.count),
            0,
            false
        )
        if count < 0, count != Int32.min {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(
                vocabulary,
                token,
                &buffer,
                Int32(buffer.count),
                0,
                false
            )
        }
        guard count >= 0 else {
            throw S1MiniServiceError.invalidOutput
        }
        return buffer.withUnsafeBytes { bytes in
            Data(bytes.prefix(Int(count)))
        }
    }
}

enum S1MiniPostProcessingService {
    static func process(
        text: String,
        modelURL: URL,
        styling: S1MiniStyling,
        structure: S1MiniStructure,
        contextSetting: S1MiniContextSetting,
        context: DictationPostProcessingContext?
    ) async throws -> String {
        let trace = PerfTrace.begin("cleanup.request")
        defer { trace.end() }
        // Literal chat markers would be interpreted as prompt boundaries.
        // Preserve that dictated content without loading or invoking a model.
        if text.contains("<|"), text.contains("|>") {
            trace.end(outcome: "literal_control_marker_fallback")
            return text
        }
        let resolvedContext = contextSetting.resolved(for: context)
        do {
            return try await processChunk(text, modelURL: modelURL, styling: styling,
                                          structure: structure, context: resolvedContext)
        } catch S1MiniServiceError.transcriptTooLong {
            // The author recommends sentence chunks near 1,000 input tokens.
            // Short dictation keeps the existing single-request fast path.
            let chunks = try await S1MiniInferenceEngine.shared.transcriptChunks(text, modelURL: modelURL)
            do {
                return try await processChunks(chunks) { chunk in
                    try await processChunk(chunk.text, modelURL: modelURL, styling: styling,
                                           structure: structure, context: resolvedContext,
                                           knownTranscriptTokenCount: chunk.tokenCount)
                }
            } catch S1MiniServiceError.outputLimitReached {
                trace.end(outcome: "output_limit_fallback")
                return text
            }
        } catch S1MiniServiceError.outputLimitReached {
            trace.end(outcome: "output_limit_fallback")
            return text
        }
    }

    /// Restore source boundaries after normalization trims the model output.
    /// Keep the raw chunk for inference so its cached token count stays exact.
    static func processChunks(
        _ chunks: [S1MiniTranscriptChunk],
        process: (S1MiniTranscriptChunk) async throws -> String
    ) async throws -> String {
        var results: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let source = TranscriptCleanupChunk(chunk.text)
            guard !source.text.isEmpty else { results.append(source.original); continue }
            let output = try await process(chunk)
            try Task.checkCancellation()
            results.append(source.replacingText(with: output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return results.joined()
    }

    private static func processChunk(
        _ text: String, modelURL: URL, styling: S1MiniStyling,
        structure: S1MiniStructure, context: String, knownTranscriptTokenCount: Int? = nil
    ) async throws -> String {
        let prompt = S1MiniPromptBuilder.prompt(
            transcript: text,
            styling: styling,
            structure: structure,
            context: context
        )
        let output = try await S1MiniInferenceEngine.shared.generate(
            prompt: prompt,
            transcript: text,
            styling: styling,
            modelURL: modelURL,
            knownTranscriptTokenCount: knownTranscriptTokenCount
        )

        guard !output.contains("<think>"), !output.contains("<|im_") else {
            throw S1MiniServiceError.invalidOutput
        }
        // S1-mini can occasionally emit EOS immediately for short input. Never
        // allow local cleanup to erase a user's transcript.
        if output.isEmpty {
            return text
        }

        let cleaned = normalizePostProcessedTranscript(output)
        if S1MiniOutputSafety.removesNumericSign(input: text, output: cleaned) {
            return text
        }
        if looksLikeNewRefusalMessage(input: text, output: cleaned) || looksLikeGeneratedContent(input: text, output: cleaned) {
            return text
        }
        return cleaned
    }

    static func unload() async {
        let trace = PerfTrace.begin("cleanup.unload")
        defer { trace.end() }
        await S1MiniInferenceEngine.shared.unload()
    }

    static func isPrepared(modelURL: URL) async -> Bool {
        await S1MiniInferenceEngine.shared.isPrepared(for: modelURL)
    }

    /// Loads the model outside the dictation path so the first cleanup is
    /// warm. Errors are swallowed: failure leaves lazy loading unchanged.
    @discardableResult
    static func prewarm(modelURL: URL) async -> Bool {
        do {
            try await S1MiniInferenceEngine.shared.prewarm(from: modelURL)
            return true
        } catch {
            return false
        }
    }
}

/// A lossless input chunk and its exact count from the installed tokenizer.
nonisolated struct S1MiniTranscriptChunk: Equatable, Sendable {
    let text: String
    let tokenCount: Int
}

/// Preserve every input character and prefer sentence boundaries. The supplied
/// counter is the installed model's tokenizer, not a word-count approximation.
nonisolated enum S1MiniTranscriptChunker {
    static func chunks(_ text: String, maximumTokens: Int,
                       tokenCount: (String) throws -> Int) throws -> [S1MiniTranscriptChunk] {
        precondition(maximumTokens > 0)
        let characters = Array(text)
        if !characters.isEmpty, characters.count <= 4_096 {
            try Task.checkCancellation()
            let count = try tokenCount(text)
            if count <= maximumTokens { return [S1MiniTranscriptChunk(text: text, tokenCount: count)] }
        }
        var offset = 0
        var result: [S1MiniTranscriptChunk] = []
        var probeHint = 512
        while offset < characters.count {
            try Task.checkCancellation()
            let remainingCount = characters.count - offset
            var counts: [Int: Int] = [:]
            func count(_ length: Int) throws -> Int {
                try Task.checkCancellation()
                if let cached = counts[length] { return cached }
                let measured = try tokenCount(String(characters[offset..<(offset + length)]))
                counts[length] = measured
                return measured
            }
            var low = 0, high = min(probeHint, remainingCount)
            while try count(high) <= maximumTokens {
                low = high
                if low == remainingCount { break }
                high = high > remainingCount / 2 ? remainingCount : high * 2
            }
            if low == remainingCount {
                result.append(S1MiniTranscriptChunk(text: String(characters[offset...]), tokenCount: try count(low)))
                break
            }
            while low + 1 < high {
                let middle = low + (high - low) / 2
                if try count(middle) <= maximumTokens { low = middle }
                else { high = middle }
            }
            probeHint = max(1, low)
            let boundaries = (1...max(1, low)).filter { characters[offset + $0 - 1].isWhitespace }
            let sentences = boundaries.filter { end in
                characters[offset + end - 1].isNewline
                    || (end > 1 && ".!?".contains(characters[offset + end - 2]))
            }
            var end = sentences.last(where: { $0 >= low / 2 }) ?? boundaries.last
            while let candidate = end {
                if try count(candidate) <= maximumTokens { break }
                end = boundaries.last(where: { $0 < candidate })
            }
            guard let end, end > 0 else {
                // Only an error needs the full remaining count for its message.
                throw S1MiniServiceError.transcriptTooLong(actual: try count(remainingCount), maximum: maximumTokens)
            }
            result.append(S1MiniTranscriptChunk(text: String(characters[offset..<(offset + end)]), tokenCount: try count(end)))
            offset += end
        }
        return result
    }
}

/// Pure gate for S1-mini startup prewarm. Kept separate from orchestration
/// so the conditions are unit-testable without loading a model.
enum S1MiniPrewarmPolicy {
    static func shouldPrewarm(
        mode: TranscriptPostProcessingMode,
        language: SupportedLanguage,
        prewarmEnabled: Bool
    ) -> Bool {
        prewarmEnabled && mode == .s1Mini && language == .english
    }
}
