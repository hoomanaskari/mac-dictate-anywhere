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
        isModelDownloaded: (ParakeetModelChoice) -> Bool,
        isAppleSpeechAssetInstalled: (SupportedLanguage) -> Bool
    ) -> InputSourceProfileResolution {
        guard enabled, let mapping else { return .none }

        switch mapping.engine {
        case .appleSpeech:
            guard appleSpeechSupported else { return .inactive }
            guard isAppleSpeechAssetInstalled(mapping.language) else { return .inactive }
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

/// Why a mapping cannot currently apply on this machine, phrased for the
/// settings UI — or nil when the mapping is active. Pure so the matrix is
/// unit-testable; the UI injects live caches/closures.
enum InputSourceMappingAvailability {
    static func inactiveReason(
        for mapping: InputSourceMapping,
        appleSpeechSupported: Bool,
        installedAppleSpeechLanguages: [SupportedLanguage],
        runnableModels: [ParakeetModelChoice],
        isModelOnDisk: (ParakeetModelChoice) -> Bool
    ) -> String? {
        switch mapping.engine {
        case .appleSpeech:
            guard appleSpeechSupported else {
                return "Apple Speech isn't available on this Mac."
            }
            guard installedAppleSpeechLanguages.contains(mapping.language) else {
                return "\(mapping.language.displayName) isn't installed for Apple Speech. Choose Apple Speech under Speech Model, then pick the language under Transcription language to download it."
            }
            return nil
        case .parakeet:
            guard let model = mapping.parakeetModel else { return nil }
            guard runnableModels.contains(model) else {
                return "\(model.displayName) isn't available on this Mac."
            }
            guard isModelOnDisk(model) else {
                return "\(model.displayName) isn't downloaded. Get it in Speech Model settings — auto-switching never downloads models."
            }
            return nil
        }
    }
}
