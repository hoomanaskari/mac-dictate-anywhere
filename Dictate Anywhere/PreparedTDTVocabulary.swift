import FluidAudio
@preconcurrency import CoreML

/// Prepared tokenizer/scorer and resident weights, scoped to one model and term list.
nonisolated enum PreparedTDTVocabulary: Sendable {
    case shared(SharedCTCVocabularySession)
    case separate(VocabularyBoostingSession, CtcModels)

    static func prepare(models: AsrModels, terms: [String], cachedCTCModels: CtcModels?,
                        cachedHead: MLModel? = nil, progressHandler: ProgressHandler? = nil) async throws -> Self {
        if models.version == .tdtCtc110m {
            let session = try await SharedCTCVocabularySession.prepare(models: models, terms: terms,
                config: VocabularyRescoringPolicy.config, cachedHead: cachedHead, progressHandler: progressHandler)
            try await session.warm()
            return .shared(session)
        }
        let ctcModels: CtcModels
        if let cachedCTCModels { ctcModels = cachedCTCModels }
        else {
            ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            _ = try await CtcKeywordSpotter(models: ctcModels).spotKeywordsWithLogProbs(
                audioSamples: [Float](repeating: 0, count: 16_000), customVocabulary: CustomVocabularyContext(terms: []))
        }
        try Task.checkCancellation()
        let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(
            terms: terms.map { CustomVocabularyTerm(text: $0) }), ctcModels: ctcModels, config: VocabularyRescoringPolicy.config)
        return .separate(session, ctcModels)
    }

    func rescore(_ original: ASRResult, samples: [Float]) async throws -> String {
        switch self {
        case .shared(let session): return try await session.rescore(original, samples: samples)
        case .separate(let session, _):
            // Only transcript replacements are consumed here. The SDK's exact
            // preflight can skip CTC when no correction needs acoustic evidence.
            guard session.hasCTCRescoringCandidates(text: original.text, tokenTimings: original.tokenTimings ?? []) else {
                try Task.checkCancellation()
                return original.text
            }
            let output = await session.rescore(text: original.text, tokenTimings: original.tokenTimings ?? [], audioSamples: samples)
            try Task.checkCancellation()
            return output?.wasModified == true ? output!.text : original.text
        }
    }
}
