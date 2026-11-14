@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Vocabulary evidence from the resident 110M fused encoder and auxiliary head.
/// This shares weights, not the previous TDT inference: FluidAudio does not
/// expose that pass's features. Other models use VocabularyBoostingSession.
nonisolated struct SharedCTCVocabularySession: Sendable {
    private let frontend: MLModel
    let head: MLModel
    private let vocabulary: CustomVocabularyContext
    private let rescorer: VocabularyRescorer
    private let thresholds: ContextBiasingConstants.VocabSizeConfig
    private static let windowSamples = 240_000
    private static let overlapSamples = 32_000
    // Whole encoder frames keep every window on the original TDT clock.
    private static let strideFrames = (windowSamples - overlapSamples) / ASRConstants.samplesPerEncoderFrame

    static func prepare(models: AsrModels, terms: [String], config: VocabularyRescorer.Config,
                        cachedHead: MLModel? = nil, progressHandler: ProgressHandler? = nil) async throws -> Self {
        guard models.version == .tdtCtc110m else {
            throw ASRError.processingFailed("110M vocabulary requires the auxiliary CTC head")
        }
        let head: MLModel
        if let resident = cachedHead ?? models.ctcHead { head = resident }
        else { head = try await VocabularyHeadLoader.load(configuration: models.configuration, progressHandler: progressHandler) }
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        if !FileManager.default.fileExists(atPath: tokenizerURL.path) {
            // Fetch only the small tokenizer. Do not download/load another encoder.
            let repo = Repo.parakeetCtc110m
            let url = URL(string: "https://huggingface.co/\(repo.remotePath)/resolve/\(repo.revision)/tokenizer.json")!
            let data = try await ModelHub.fetchFile(from: url, description: "110M CTC vocabulary tokenizer")
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: tokenizerURL, options: .atomic)
        }
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let vocabulary = CustomVocabularyContext(terms: terms.compactMap { term in
            let ids = tokenizer.encode(term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
        })
        // The SDK's constrained scorer requires a spotter carrying CtcModels.
        // It only calls pure log-probability scoring here; never its staged
        // mel/encoder inference methods. These references allocate no weights.
        let scoringModels = CtcModels(melSpectrogram: models.preprocessor, encoder: head,
                                      configuration: models.configuration, vocabulary: models.vocabulary)
        let spotter = CtcKeywordSpotter(models: scoringModels, blankId: models.version.blankId)
        let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocabulary,
                                                          config: config, ctcModelDirectory: directory)
        return Self(frontend: models.preprocessor, head: head, vocabulary: vocabulary,
                    rescorer: rescorer,
                    thresholds: ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count))
    }

    func rescore(_ original: ASRResult, samples: [Float]) async throws -> String {
        guard !vocabulary.terms.isEmpty, let timings = original.tokenTimings, !timings.isEmpty,
              !samples.isEmpty else { return original.text }
        // Use the same candidate rules and threshold as the acoustic scorer.
        guard rescorer.hasCTCRescoringCandidates(transcript: original.text, tokenTimings: timings,
            minSimilarity: max(thresholds.minSimilarity, vocabulary.minSimilarity)) else {
            try Task.checkCancellation()
            return original.text
        }
        let evidence = try await logProbabilities(samples: samples)
        try Task.checkCancellation()
        let result = rescorer.ctcTokenRescore(transcript: original.text, tokenTimings: timings,
            logProbs: evidence.frames, frameDuration: evidence.frameDuration,
            cbw: thresholds.cbw, marginSeconds: 0.5,
            minSimilarity: max(thresholds.minSimilarity, vocabulary.minSimilarity))
        return result.wasModified ? result.text : original.text
    }

    func warm() async throws {
        _ = try await logProbabilities(samples: [Float](repeating: 0, count: 16_000))
    }

    /// Use 15-second windows with at least two seconds of overlap, aligned to
    /// the TDT encoder's 80 ms grid. Partial padding never changes frame time.
    /// Merge overlapping probabilities on that same original-audio clock.
    func logProbabilities(samples: [Float]) async throws -> (frames: [[Float]], frameDuration: Double) {
        var combined: [[Float]] = []
        var frameDuration: Double = 0
        var start = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(start + Self.windowSamples, samples.count)
            let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
            let pointer = audio.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
            pointer.initialize(repeating: 0, count: Self.windowSamples)
            for i in start..<end { pointer[i - start] = samples[i] }
            let length = try MLMultiArray(shape: [1], dataType: .int32)
            length[0] = NSNumber(value: end - start)
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": MLFeatureValue(multiArray: audio), "audio_length": MLFeatureValue(multiArray: length)])
            let encoded = try await frontend.compatPrediction(from: input, options: AsrModels.optimizedPredictionOptions())
            guard let features = encoded.featureValue(for: "encoder")?.multiArrayValue else {
                throw ASRError.processingFailed("110M frontend did not return encoder features")
            }
            let headInput = try MLDictionaryFeatureProvider(dictionary: ["encoder_output": MLFeatureValue(multiArray: features)])
            let predicted = try await head.compatPrediction(from: headInput, options: AsrModels.optimizedPredictionOptions())
            guard let logits = predicted.featureValue(for: "ctc_logits")?.multiArrayValue,
                  logits.shape.count == 3, logits.shape[0].intValue == 1,
                  logits.shape[2].intValue == 1025 else {
                throw ASRError.processingFailed("110M CTC head returned an unsupported frame grid")
            }
            let totalFrames = logits.shape[1].intValue
            guard totalFrames > 0 else { throw ASRError.processingFailed("110M CTC head returned no frames") }
            frameDuration = ASRConstants.secondsPerEncoderFrame
            guard let validFrames = encoded.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue,
                  validFrames > 0, validFrames <= totalFrames else {
                throw ASRError.processingFailed("110M frontend returned an invalid encoder length")
            }
            let frameStride = logits.strides[1].intValue, tokenStride = logits.strides[2].intValue
            guard logits.dataType == .float32 else { throw ASRError.processingFailed("110M CTC logits must be Float32") }
            let storageSpan = (totalFrames - 1) * frameStride + 1024 * tokenStride + 1
            let values = logits.dataPointer.bindMemory(to: Float.self, capacity: storageSpan)
            let raw = (0..<validFrames).map { frame in
                (0..<1025).map { token in values[frame * frameStride + token * tokenStride] }
            }
            guard raw.allSatisfy({ row in row.contains(where: { $0.isFinite }) && row.allSatisfy { $0.isFinite || $0 == -.infinity } }) else {
                throw ASRError.processingFailed("110M CTC head returned invalid probabilities")
            }
            // The exported head emits log probabilities; log-softmax is
            // idempotent here and retains SDK temperature/blank-bias handling.
            let frames = CtcKeywordSpotter.applyLogSoftmax(rawLogits: raw, blankId: 1024)
            if combined.isEmpty { combined = frames }
            else {
                let startFrame = start / ASRConstants.samplesPerEncoderFrame
                let overlap = min(max(0, combined.count - startFrame), frames.count)
                for i in 0..<overlap {
                    let index = combined.count - overlap + i
                    combined[index] = zip(combined[index], frames[i]).map { a, b in
                        let maximum = max(a, b)
                        return maximum == -.infinity ? -.infinity : maximum + log(exp(a - maximum) + exp(b - maximum)) - log(2)
                    }
                }
                combined.append(contentsOf: frames.dropFirst(overlap))
            }
            if end == samples.count { break }
            start += Self.strideFrames * ASRConstants.samplesPerEncoderFrame
        }
        return (combined, frameDuration)
    }
}
