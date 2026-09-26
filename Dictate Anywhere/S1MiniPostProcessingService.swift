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

enum S1MiniPromptBuilder {
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
    private var loadedModelPath: String?
    private var backendInitialized = false

    deinit {
        if let model {
            llama_model_free(model)
        }
        if backendInitialized {
            llama_backend_free()
        }
    }

    func unload() {
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        loadedModelPath = nil
    }

    func generate(
        prompt: String,
        transcript: String,
        modelURL: URL
    ) throws -> String {
        let trace = PerfTrace.begin("cleanup.generate")
        defer { trace.end() }
        let model = try loadModelIfNeeded(from: modelURL)
        guard let vocabulary = llama_model_get_vocab(model) else {
            throw S1MiniServiceError.modelLoadFailed
        }

        let (transcriptTokenCount, initialPromptTokens) = try tokenizeInputs(
            transcript: transcript,
            prompt: prompt,
            vocabulary: vocabulary
        )
        var promptTokens = initialPromptTokens
        let maximumOutputTokens = min(
            1_024,
            max(32, Int(ceil(Double(transcriptTokenCount) * 1.3)) + 32)
        )
        trace.recordCounts([
            "input_tokens": transcriptTokenCount,
            "prompt_tokens": promptTokens.count
        ])
        // Keep the documented llama.cpp context size. Reducing Qwen3's context
        // dynamically changes logits enough for S1-mini to emit EOS on valid
        // short transcripts.
        let contextSize = 4_096

        // Context allocation plus prompt evaluation: the remaining timed
        // portion of generate() besides model load, tokenize, and decode.
        let promptEvalTrace = PerfTrace.begin("cleanup.promptEval")
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(contextSize)
        contextParameters.n_batch = 2_048
        contextParameters.n_ubatch = 512
        contextParameters.n_outputs_max = 1
        contextParameters.n_outputs_max_per_seq = 1
        // Q8 KV cache cuts per-request context memory roughly in half while
        // preserving materially the same logits as the default F16 cache.
        contextParameters.type_k = GGML_TYPE_Q8_0
        contextParameters.type_v = GGML_TYPE_Q8_0
        let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        contextParameters.n_threads = threadCount
        contextParameters.n_threads_batch = threadCount

        guard let context = llama_init_from_model(model, contextParameters) else {
            promptEvalTrace.end()
            throw S1MiniServiceError.contextCreationFailed
        }
        defer { llama_free(context) }

        let promptStatus = promptTokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(
                context,
                llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
            )
        }
        guard promptStatus == 0 else {
            promptEvalTrace.end()
            throw S1MiniServiceError.promptEvaluationFailed(promptStatus)
        }
        promptEvalTrace.end()

        let (output, outputTokenCount) = try sampleOutput(
            context: context,
            vocabulary: vocabulary,
            maximumOutputTokens: maximumOutputTokens
        )
        trace.recordCounts(["output_tokens": outputTokenCount, "output_bytes": output.count])

        let decoded = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info(
            "generate: promptTokens=\(promptTokens.count, privacy: .public), inputTokens=\(transcriptTokenCount, privacy: .public), outputChars=\(decoded.count, privacy: .public)"
        )
        return decoded
    }

    /// Tokenizes the transcript (for the length guard) and the prompt.
    /// Traced separately so future work can distinguish tokenizer cost
    /// from context setup, prompt evaluation, and sampling.
    private func tokenizeInputs(
        transcript: String,
        prompt: String,
        vocabulary: OpaquePointer
    ) throws -> (transcriptTokenCount: Int, promptTokens: [llama_token]) {
        let trace = PerfTrace.begin("cleanup.tokenize")
        defer { trace.end() }
        let transcriptTokenCount = try tokenize(
            transcript,
            vocabulary: vocabulary,
            addSpecial: false,
            parseSpecial: false
        ).count
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
        return (transcriptTokenCount, promptTokens)
    }

    /// Runs the autoregressive sampling loop. Traced separately so future
    /// work can derive per-token timings from the existing token counts.
    private func sampleOutput(
        context: OpaquePointer,
        vocabulary: OpaquePointer,
        maximumOutputTokens: Int
    ) throws -> (Data, Int) {
        let trace = PerfTrace.begin("cleanup.decode")
        defer { trace.end() }
        var output = Data()
        var outputTokenCount = 0
        for _ in 0..<maximumOutputTokens {
            try Task.checkCancellation()
            let token = try greedyToken(context: context, vocabulary: vocabulary)
            if llama_vocab_is_eog(vocabulary, token) {
                break
            }
            outputTokenCount += 1
            output.append(try piece(for: token, vocabulary: vocabulary))

            var nextToken = token
            let tokenStatus = llama_decode(
                context,
                llama_batch_get_one(&nextToken, 1)
            )
            guard tokenStatus == 0 else {
                throw S1MiniServiceError.tokenEvaluationFailed(tokenStatus)
            }
        }
        trace.recordCounts(["output_tokens": outputTokenCount])
        return (output, outputTokenCount)
    }

    private func loadModelIfNeeded(from url: URL) throws -> OpaquePointer {
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

    private func greedyToken(
        context: OpaquePointer,
        vocabulary: OpaquePointer
    ) throws -> llama_token {
        guard let logits = llama_get_logits_ith(context, -1) else {
            throw S1MiniServiceError.invalidOutput
        }
        let count = Int(llama_vocab_n_tokens(vocabulary))
        guard count > 0 else {
            throw S1MiniServiceError.invalidOutput
        }

        var selected = 0
        var maximum = logits[0]
        for index in 1..<count where logits[index] > maximum {
            selected = index
            maximum = logits[index]
        }
        return llama_token(selected)
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
        let resolvedContext = contextSetting.resolved(for: context)
        let prompt = S1MiniPromptBuilder.prompt(
            transcript: text,
            styling: styling,
            structure: structure,
            context: resolvedContext
        )
        let output = try await S1MiniInferenceEngine.shared.generate(
            prompt: prompt,
            transcript: text,
            modelURL: modelURL
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
        if looksLikeRefusalMessage(cleaned) || looksLikeGeneratedContent(input: text, output: cleaned) {
            return text
        }
        return cleaned
    }

    static func unload() async {
        let trace = PerfTrace.begin("cleanup.unload")
        defer { trace.end() }
        await S1MiniInferenceEngine.shared.unload()
    }
}
