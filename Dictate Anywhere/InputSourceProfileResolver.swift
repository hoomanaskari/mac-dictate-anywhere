//
//  InputSourceProfileResolver.swift
//  Dictate Anywhere
//
//  Pure decision logic for input-source auto-switching: given a mapping and
//  the current engine state, decides what (if anything) must change.
//

import Foundation

enum InputSourceProfileResolution: Equatable {
    /// Feature disabled, source unmapped, or mapping malformed.
    case none
    /// Profile already active.
    case noChange
    /// Same engine and model; only the language differs.
    case languageOnly(SupportedLanguage)
    /// Engine and/or model must change (expensive path).
    case fullApply
    /// Mapping cannot be applied (model not downloaded / engine unsupported).
    case inactive
}

enum InputSourceProfileResolver {
    static func resolve(
        mapping: InputSourceMapping?,
        enabled: Bool,
        currentEngine: TranscriptionEngineChoice,
        currentParakeetModel: ParakeetModelChoice,
        currentFluidAudioLanguage: SupportedLanguage,
        currentAppleSpeechLanguage: SupportedLanguage,
        appleSpeechSupported: Bool,
        isModelDownloaded: (ParakeetModelChoice) -> Bool
    ) -> InputSourceProfileResolution {
        guard enabled, let mapping else { return .none }

        switch mapping.engine {
        case .appleSpeech:
            guard appleSpeechSupported else { return .inactive }
            guard currentEngine == .appleSpeech else { return .fullApply }
            return mapping.language == currentAppleSpeechLanguage
                ? .noChange
                : .languageOnly(mapping.language)

        case .parakeet:
            guard let model = mapping.parakeetModel else { return .none }
            guard isModelDownloaded(model) else { return .inactive }
            guard currentEngine == .parakeet, model == currentParakeetModel else { return .fullApply }
            return mapping.language == currentFluidAudioLanguage
                ? .noChange
                : .languageOnly(mapping.language)
        }
    }
}
