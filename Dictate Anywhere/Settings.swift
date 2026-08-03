//
//  Settings.swift
//  Dictate Anywhere
//
//  Centralized settings management with UserDefaults persistence.
//

import Foundation
import AppKit
import ServiceManagement
import IOKit.hidsystem
import Security

private enum KeychainSecretStore {
    nonisolated static func read(service: String, account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    nonisolated static func write(_ value: String, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmedValue.utf8)
        let attributesToUpdate = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            SecItemAdd(createQuery as CFDictionary, nil)
        }
    }
}

// MARK: - App Appearance Mode

enum AppAppearanceMode: String, CaseIterable {
    case menuBarOnly = "menuBarOnly"
    case dockAndMenuBar = "dockAndMenuBar"

    nonisolated var displayName: String {
        switch self {
        case .menuBarOnly: return "Menu Bar Only"
        case .dockAndMenuBar: return "Dock and Menu Bar"
        }
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .menuBarOnly: return .accessory
        case .dockAndMenuBar: return .regular
        }
    }
}

// MARK: - Transcription Engine Choice

enum TranscriptionEngineChoice: String, CaseIterable, Codable {
    case parakeet = "parakeet"
    case appleSpeech = "appleSpeech"

    nonisolated var displayName: String {
        switch self {
        case .parakeet: return "FluidAudio"
        case .appleSpeech: return "Apple Speech"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .parakeet:
            return "Downloadable on-device speech models powered by FluidAudio."
        case .appleSpeech:
            return "Apple's latest on-device speech-to-text model, managed by macOS."
        }
    }
}

enum ParakeetModelChoice: String, CaseIterable, Codable {
    case multilingual = "multilingual"
    case englishOnly = "englishOnly"
    case compactEnglish = "compactEnglish"
    case parakeetEou320 = "parakeetEou320"
    case nemotron560 = "nemotron560"
    case nemotron1120 = "nemotron1120"
    case nemotron2240 = "nemotron2240"
    case senseVoice = "senseVoice"
    case nemotronMultilingual = "nemotronMultilingual"

    nonisolated var displayName: String {
        switch self {
        case .multilingual: return "Multilingual"
        case .englishOnly: return "English Only"
        case .compactEnglish: return "English Compact (110M)"
        case .parakeetEou320: return "Parakeet EOU Streaming"
        case .nemotron560: return "Nemotron Streaming (560 ms)"
        case .nemotron1120: return "Nemotron Streaming (1120 ms)"
        case .nemotron2240: return "Nemotron Streaming (2240 ms)"
        case .senseVoice: return "Chinese (SenseVoice)"
        case .nemotronMultilingual: return "Multilingual Streaming (Nemotron)"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .multilingual:
            return "25 European languages with automatic language detection."
        case .englishOnly:
            return "English-only vocabulary tuned for stronger English accuracy."
        case .compactEnglish:
            return "Smaller English-only Parakeet model with faster downloads and lower memory use."
        case .parakeetEou320:
            return "True streaming English dictation with end-of-speech detection and lower preview latency."
        case .nemotron560:
            return "True streaming English dictation with the lowest Nemotron latency tier."
        case .nemotron1120:
            return "True streaming English dictation with a balanced Nemotron latency and accuracy tier."
        case .nemotron2240:
            return "True streaming English dictation with Nemotron's higher-throughput tier."
        case .senseVoice:
            return "Chinese (Simplified) dictation with mixed English, native punctuation, and the best accuracy for Mandarin."
        case .nemotronMultilingual:
            return "True streaming dictation across 40+ languages including Chinese, with lower accuracy than SenseVoice for Mandarin."
        }
    }

    nonisolated var modelDirectoryName: String {
        switch self {
        case .multilingual:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .englishOnly:
            return "parakeet-tdt-0.6b-v2-coreml"
        case .compactEnglish:
            return "parakeet-tdt-ctc-110m"
        case .parakeetEou320:
            return "parakeet-eou-streaming/320ms"
        case .nemotron560:
            return "nemotron-streaming/560ms"
        case .nemotron1120:
            return "nemotron-streaming/1120ms"
        case .nemotron2240:
            return "nemotron-streaming/2240ms"
        case .senseVoice:
            return "sensevoice-small"
        case .nemotronMultilingual:
            return "nemotron-multilingual/multilingual/1120ms"
        }
    }

    nonisolated var isEnglishOnly: Bool {
        switch self {
        case .multilingual, .senseVoice, .nemotronMultilingual:
            return false
        case .englishOnly, .compactEnglish, .parakeetEou320, .nemotron560, .nemotron1120, .nemotron2240:
            return true
        }
    }

    nonisolated var usesTrueStreaming: Bool {
        switch self {
        case .multilingual, .englishOnly, .compactEnglish, .senseVoice:
            return false
        case .parakeetEou320, .nemotron560, .nemotron1120, .nemotron2240, .nemotronMultilingual:
            return true
        }
    }

    nonisolated var supportsEndOfUtterance: Bool {
        switch self {
        case .parakeetEou320:
            return true
        case .multilingual, .englishOnly, .compactEnglish, .nemotron560, .nemotron1120, .nemotron2240,
             .senseVoice, .nemotronMultilingual:
            return false
        }
    }

    nonisolated var languageSummary: String {
        switch self {
        case .multilingual: return "25 European languages"
        case .senseVoice: return "Chinese (Simplified) + English; also Cantonese, Japanese, Korean"
        case .nemotronMultilingual: return "40+ languages including Chinese"
        case .englishOnly, .compactEnglish, .parakeetEou320, .nemotron560, .nemotron1120, .nemotron2240:
            return "English only"
        }
    }

    nonisolated var sizeSummary: String {
        switch self {
        case .multilingual, .englishOnly:
            return "~500 MB"
        case .compactEnglish:
            return "~220 MB"
        case .parakeetEou320:
            return "~200 MB"
        case .nemotron560, .nemotron1120, .nemotron2240:
            return "~1 GB"
        case .senseVoice:
            // Without ANE access we download the fp32 encoder instead of int8.
            return Hardware.canUseAppleNeuralEngine ? "~225 MB" : "~900 MB"
        case .nemotronMultilingual:
            return "~650 MB"
        }
    }

    nonisolated var languageSettingsFooter: String {
        switch self {
        case .multilingual:
            return "The multilingual Parakeet model auto-detects among 25 supported European languages."
        case .englishOnly:
            return "The English-only Parakeet model is optimized for English dictation."
        case .compactEnglish:
            return "The compact 110M Parakeet model is English-only and optimized for faster startup with lower memory use."
        case .parakeetEou320, .nemotron560, .nemotron1120, .nemotron2240:
            return "The selected streaming model is English-only. Choose Multilingual if you dictate in other languages."
        case .senseVoice:
            return "SenseVoice auto-detects Chinese (Simplified) and English, including mixed-language dictation. Output uses Simplified characters."
        case .nemotronMultilingual:
            return "The multilingual Nemotron model streams transcription with a language hint for the selected language when available, including Chinese (Simplified); other languages fall back to automatic detection."
        }
    }

    nonisolated var speechModelFooter: String {
        switch self {
        case .multilingual:
            return "Choose Multilingual for automatic language detection across 25 supported languages."
        case .englishOnly:
            return "Choose English Only for stronger English accuracy when you never dictate in other languages."
        case .compactEnglish:
            return "Choose English Compact (110M) for a smaller, faster English-only model when download size and memory use matter most."
        case .parakeetEou320:
            return "Choose Parakeet EOU Streaming to test lower-latency true streaming and end-of-speech detection."
        case .nemotron560:
            return "Choose Nemotron 560 ms for the lowest Nemotron streaming latency."
        case .nemotron1120:
            return "Choose Nemotron 1120 ms for a balanced streaming option."
        case .nemotron2240:
            return "Choose Nemotron 2240 ms for the higher-throughput streaming option."
        case .senseVoice:
            return "Choose Chinese (SenseVoice) for the most accurate Mandarin dictation with native punctuation and mixed English support."
        case .nemotronMultilingual:
            return "Choose Multilingual Streaming (Nemotron) for lower-latency live preview in Chinese and 40+ other languages, at reduced accuracy."
        }
    }

    /// Languages offered in the language picker, or nil when the model's
    /// language handling is fixed (picker hidden, `fixedLanguageLabel` shown).
    nonisolated var selectableLanguages: [SupportedLanguage]? {
        switch self {
        case .multilingual:
            return SupportedLanguage.allCases.filter { $0 != .chinese }
        case .nemotronMultilingual:
            return SupportedLanguage.allCases
        case .senseVoice, .englishOnly, .compactEnglish, .parakeetEou320,
             .nemotron560, .nemotron1120, .nemotron2240:
            return nil
        }
    }

    nonisolated var fixedLanguageLabel: String? {
        switch self {
        case .senseVoice:
            return "Chinese + English (auto-detected)"
        case .englishOnly, .compactEnglish, .parakeetEou320,
             .nemotron560, .nemotron1120, .nemotron2240:
            return "English"
        case .multilingual, .nemotronMultilingual:
            return nil
        }
    }

    nonisolated func supportsLanguage(_ language: SupportedLanguage) -> Bool {
        switch self {
        case .senseVoice, .nemotronMultilingual:
            return true
        case .multilingual:
            return language != .chinese
        case .englishOnly, .compactEnglish, .parakeetEou320,
             .nemotron560, .nemotron1120, .nemotron2240:
            return language == .english
        }
    }

    /// FluidAudio vocabulary rescoring runs terms through the English-only
    /// ctc110m tokenizer — unusable for Han text, so the Mandarin-capable
    /// models opt out.
    nonisolated var supportsFluidAudioVocabulary: Bool {
        switch self {
        case .senseVoice, .nemotronMultilingual: return false
        default: return true
        }
    }

    /// Nemotron multilingual ships only an int8 ANE-targeted encoder and is
    /// documented by FluidAudio as "Apple Silicon only", with no CPU build to
    /// fall back to. FluidAudio enforces that with a compile-time
    /// `guard SystemInfo.isAppleSilicon else { throw ASRError.unsupportedPlatform }`,
    /// so it also refuses on the x86_64 slice of our universal binary running
    /// under Rosetta. Hide it wherever `Hardware.canUseAppleNeuralEngine` is
    /// false rather than let a user pick a model that can only fail after a
    /// ~650 MB download.
    ///
    /// SenseVoice is deliberately not listed here: its fp16/int8 encoders are
    /// ANE-only, but FluidAudio also ships an fp32 encoder that runs on any
    /// compute unit, which `ParakeetEngine.senseVoiceEncoderPrecision` selects
    /// on non-ANE hardware.
    nonisolated var requiresAppleNeuralEngine: Bool {
        switch self {
        case .nemotronMultilingual:
            return true
        case .multilingual, .englishOnly, .compactEnglish, .parakeetEou320,
             .nemotron560, .nemotron1120, .nemotron2240, .senseVoice:
            return false
        }
    }

    // The `hasNeuralEngine` parameter exists so the non-ANE outcome (Intel, or
    // our x86_64 slice under Rosetta) is testable from an arm64 test run;
    // production callers use the no-argument variants, which read
    // `Hardware.canUseAppleNeuralEngine` — a compile-time property of this
    // process, not a runtime probe of the host.

    nonisolated func isAvailable(hasNeuralEngine: Bool) -> Bool {
        !requiresAppleNeuralEngine || hasNeuralEngine
    }

    nonisolated var isAvailableOnThisMac: Bool {
        isAvailable(hasNeuralEngine: Hardware.canUseAppleNeuralEngine)
    }

    nonisolated static func availableCases(hasNeuralEngine: Bool) -> [ParakeetModelChoice] {
        allCases.filter { $0.isAvailable(hasNeuralEngine: hasNeuralEngine) }
    }

    /// Models this Mac can actually run — the list the picker offers.
    nonisolated static var availableCases: [ParakeetModelChoice] {
        availableCases(hasNeuralEngine: Hardware.canUseAppleNeuralEngine)
    }

    /// Fallback when a stored selection isn't runnable on this hardware.
    nonisolated static func availableFallback(
        for language: SupportedLanguage,
        hasNeuralEngine: Bool
    ) -> ParakeetModelChoice {
        let runnable = availableCases(hasNeuralEngine: hasNeuralEngine)
        if let match = runnable.first(where: { $0.supportsLanguage(language) }) {
            return match
        }
        return runnable.first ?? .multilingual
    }

    nonisolated static func availableFallback(for language: SupportedLanguage) -> ParakeetModelChoice {
        availableFallback(for: language, hasNeuralEngine: Hardware.canUseAppleNeuralEngine)
    }
}

enum TranscriptPostProcessingMode: String, CaseIterable {
    case none = "none"
    case fluidAudioVocabulary = "fluidAudioVocabulary"
    case appleIntelligence = "appleIntelligence"
    case ollama = "ollama"
    case openRouter = "openRouter"
    case openAICompatible = "openAICompatible"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .fluidAudioVocabulary: return "FluidAudio Vocabulary"
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama: return "Ollama"
        case .openRouter: return "OpenRouter"
        case .openAICompatible: return "OpenAI Compatible"
        }
    }
}

enum OllamaReasoningCapability: String, Sendable {
    case unsupported = "unsupported"
    case toggle = "toggle"
    case level = "level"

    var supportsReasoning: Bool {
        self != .unsupported
    }
}

enum OllamaReasoningSetting: String, CaseIterable, Sendable {
    case automatic = "automatic"
    case disabled = "disabled"
    case enabled = "enabled"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .disabled: return "Off"
        case .enabled: return "On"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    static func options(for capability: OllamaReasoningCapability) -> [Self] {
        switch capability {
        case .unsupported:
            return []
        case .toggle:
            return [.automatic, .disabled, .enabled]
        case .level:
            return [.automatic, .low, .medium, .high]
        }
    }

    func sanitized(for capability: OllamaReasoningCapability) -> Self {
        switch capability {
        case .unsupported:
            return self
        case .toggle:
            switch self {
            case .automatic, .disabled, .enabled:
                return self
            case .low, .medium, .high:
                return .enabled
            }
        case .level:
            switch self {
            case .automatic, .low, .medium, .high:
                return self
            case .disabled, .enabled:
                return .automatic
            }
        }
    }
}

// MARK: - Hotkey Mode

enum HotkeyMode: String, CaseIterable, Codable {
    case holdToRecord = "holdToRecord"
    case handsFreeToggle = "handsFreeToggle"

    var displayName: String {
        switch self {
        case .holdToRecord: return "Hold to Record"
        case .handsFreeToggle: return "Tap to Toggle"
        }
    }
}

// MARK: - Hotkey Binding

nonisolated struct HotkeyModifiers: OptionSet, Codable, Equatable {
    let rawValue: UInt64

    static let command = HotkeyModifiers(rawValue: CGEventFlags.maskCommand.rawValue)
    static let control = HotkeyModifiers(rawValue: CGEventFlags.maskControl.rawValue)
    static let option = HotkeyModifiers(rawValue: CGEventFlags.maskAlternate.rawValue)
    static let shift = HotkeyModifiers(rawValue: CGEventFlags.maskShift.rawValue)
    static let function = HotkeyModifiers(rawValue: CGEventFlags.maskSecondaryFn.rawValue)
    // Retained for migration/sanitization only. Caps Lock is not supported as a hotkey.
    static let capsLock = HotkeyModifiers(rawValue: CGEventFlags.maskAlphaShift.rawValue)

    static let leftControl = HotkeyModifiers(rawValue: UInt64(NX_DEVICELCTLKEYMASK))
    static let rightControl = HotkeyModifiers(rawValue: UInt64(NX_DEVICERCTLKEYMASK))
    static let leftShift = HotkeyModifiers(rawValue: UInt64(NX_DEVICELSHIFTKEYMASK))
    static let rightShift = HotkeyModifiers(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))
    static let leftCommand = HotkeyModifiers(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
    static let rightCommand = HotkeyModifiers(rawValue: UInt64(NX_DEVICERCMDKEYMASK))
    static let leftOption = HotkeyModifiers(rawValue: UInt64(NX_DEVICELALTKEYMASK))
    static let rightOption = HotkeyModifiers(rawValue: UInt64(NX_DEVICERALTKEYMASK))

    static let relevant: HotkeyModifiers = [
        .command, .control, .option, .shift, .function,
        .leftControl, .rightControl, .leftShift, .rightShift,
        .leftCommand, .rightCommand, .leftOption, .rightOption,
    ]
}

struct HotkeyBinding: Codable, Identifiable, Equatable {
    var id: UUID
    var keyCode: UInt16?
    var modifiersRawValue: UInt64
    var displayName: String
    var mode: HotkeyMode

    nonisolated var modifiers: HotkeyModifiers {
        get { Settings.normalizedHotkeyModifiers(HotkeyModifiers(rawValue: modifiersRawValue)) }
        set { modifiersRawValue = Settings.normalizedHotkeyModifiers(newValue).rawValue }
    }

    var hasBinding: Bool {
        keyCode != nil || !modifiers.isEmpty
    }

    /// Default binding: ⌃⌥⌘ (modifier-only), hold to record
    static let defaultBinding = HotkeyBinding(
        id: UUID(),
        keyCode: nil,
        modifiersRawValue: HotkeyModifiers([.control, .option, .command]).rawValue,
        displayName: "\u{2303}\u{2325}\u{2318}",
        mode: .holdToRecord
    )
}

/// One user-configured input-source → transcription-profile mapping.
/// Language/model capability is never stored here — it is always resolved
/// through `ParakeetModelChoice` / Apple Speech at read time.
struct InputSourceMapping: Codable, Identifiable, Equatable {
    var id: UUID
    var inputSourceID: String
    /// Cached for display when the source is no longer enabled in macOS.
    var inputSourceDisplayName: String
    var engine: TranscriptionEngineChoice
    /// Present iff `engine == .parakeet`.
    var parakeetModel: ParakeetModelChoice?
    var language: SupportedLanguage
}

/// Decode-tolerant shape: enum raw values may vanish across app versions,
/// and a strict `[InputSourceMapping]` decode would throw away every entry.
private struct RawInputSourceMapping: Decodable {
    let id: UUID
    let inputSourceID: String
    let inputSourceDisplayName: String
    let engine: String
    let parakeetModel: String?
    let language: String
}

struct TranscriptHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
}

// MARK: - Conflict Detector

enum ConflictDetector {
    /// Checks if a binding duplicates another binding in the array (by key combo, ignoring mode)
    static func internalConflict(for binding: HotkeyBinding, in bindings: [HotkeyBinding]) -> String? {
        guard binding.hasBinding else { return nil }
        let normalizedMods = binding.modifiers
        for other in bindings where other.id != binding.id && other.hasBinding {
            let otherMods = other.modifiers
            if other.keyCode == binding.keyCode && otherMods == normalizedMods {
                return "Duplicate of another shortcut"
            }
        }
        return nil
    }

    /// Checks if a binding conflicts with well-known macOS system shortcuts
    static func systemConflict(for binding: HotkeyBinding) -> String? {
        guard binding.hasBinding else { return nil }
        let mods = Settings.deviceIndependentModifiers(from: binding.modifiers)
        let key = binding.keyCode

        // Known system shortcuts: (keyCode, modifiers, description)
        let systemShortcuts: [(UInt16?, HotkeyModifiers, String)] = [
            (49, .command, "Spotlight"),                                           // ⌘Space
            (49, [.command, .option], "Finder Search"),                            // ⌘⌥Space
            (nil, [.control, .command], "Dictation"),                              // ⌃⌘ (modifier-only)
            (12, [.command, .option], "Force Quit"),                               // ⌘⌥Q
            (53, [.command, .option], "Force Quit"),                               // ⌘⌥Esc
            (20, [.command, .shift], "Screenshot area"),                           // ⌘⇧3
            (21, [.command, .shift], "Screenshot selection"),                      // ⌘⇧4
            (23, [.command, .shift], "Screenshot options"),                        // ⌘⇧5
        ]

        for (sysKey, sysMods, desc) in systemShortcuts {
            if key == sysKey && mods == sysMods {
                return "Conflicts with macOS \(desc)"
            }
        }
        return nil
    }
}

@Observable
final class Settings {
    // MARK: - Singleton

    static let shared = Settings()
    static let recommendedTranscriptCleanupPrompt = """
    Never use em dashes. Replace them with commas, periods, colons, semicolons, or parentheses when needed.

    If the speaker corrects themselves or changes their mind, keep the latest intended meaning. Replace only the part that is clearly being corrected, and keep the rest.

    Auto structure into paragraphs and list items with proper punctuation when appropriate.

    Format spoken numbers into numerals when that improves clarity while preserving intended units and symbols. Example: "thirteen point five percent" -> "13.5%".

    Remove unnecessary and erroneous word repetitions, but keep deliberate repetition when it is clearly intentional.

    Stay faithful to the original transcript's tone.

    Treat custom vocabulary as a strong hint, not a hard rule. If a suggested term does not semantically fit the sentence, prefer the wording that best matches the surrounding context.
    """
    private nonisolated static let functionKeyCodes: Set<UInt16> = [63, 179]
    private nonisolated static let openRouterAPIKeyKeychainAccount = "openrouter-api-key"
    private nonisolated static let openAICompatibleAPIKeyKeychainAccount = "openai-compatible-api-key"

    /// Background queue for sound playback
    private let soundQueue = DispatchQueue(label: "com.dictate-anywhere.sounds", qos: .userInteractive)

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyBindings = "hotkeyBindings"
        // Legacy keys for migration
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyDisplayName = "hotkeyDisplayName"
        static let hotkeyMode = "hotkeyMode"
        static let engineChoice = "engineChoice"
        static let parakeetModelChoice = "parakeetModelChoice"
        static let selectedLanguage = "selectedLanguage"
        static let appleSpeechLanguage = "appleSpeechLanguage"
        static let isFillerWordRemovalEnabled = "isFillerWordRemovalEnabled"
        static let fillerWordsToRemove = "fillerWordsToRemove"
        static let boostMicrophoneVolumeEnabled = "boostMicrophoneVolumeEnabled"
        static let muteSystemAudioDuringRecordingEnabled = "muteSystemAudioDuringRecordingEnabled"
        static let autoStopAfterSpeechEndsEnabled = "autoStopAfterSpeechEndsEnabled"
        static let legacyAutoVolumeEnabled = "autoVolumeEnabled"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let soundEffectsVolume = "soundEffectsVolume"
        static let showTextPreview = "showTextPreview"
        static let launchAtLogin = "launchAtLogin"
        static let appAppearanceMode = "appAppearanceMode"
        static let selectedMicrophoneUID = "selectedMicrophoneUID"
        static let userHasChosenEngine = "userHasChosenEngine"
        static let legacyAppleSpeechMigrationPending = "legacyAppleSpeechMigrationPending"
        static let aiPostProcessingEnabled = "aiPostProcessingEnabled"
        static let aiPostProcessingPrompt = "aiPostProcessingPrompt"
        static let customVocabulary = "customVocabulary"
        static let transcriptHistory = "transcriptHistory"
        static let transcriptPostProcessingMode = "transcriptPostProcessingMode"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let ollamaReasoningSetting = "ollamaReasoningSetting"
        static let ollamaPostProcessingPrompt = "ollamaPostProcessingPrompt"
        static let openRouterModel = "openRouterModel"
        static let openRouterPostProcessingPrompt = "openRouterPostProcessingPrompt"
        static let openRouterAPIKeyEnvironmentVariable = "openRouterAPIKeyEnvironmentVariable"
        static let openAICompatibleBaseURL = "openAICompatibleBaseURL"
        static let openAICompatibleModel = "openAICompatibleModel"
        static let openAICompatiblePostProcessingPrompt = "openAICompatiblePostProcessingPrompt"
        static let inputSourceMappings = "inputSourceMappings"
        static let inputSourceAutoSwitchEnabled = "inputSourceAutoSwitchEnabled"
        static let pendingVocabularyModeRestore = "pendingVocabularyModeRestore"
    }

    // MARK: - Hotkey Settings

    /// All configured hotkey bindings
    var hotkeyBindings: [HotkeyBinding] {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkeyBindings) else { return }
            UserDefaults.standard.set(data, forKey: Keys.hotkeyBindings)
        }
    }

    /// Whether any hotkey has been configured
    var hasHotkey: Bool {
        hotkeyBindings.contains { $0.hasBinding }
    }

    // MARK: - Engine Settings

    /// Which transcription engine to use
    var engineChoice: TranscriptionEngineChoice {
        didSet {
            UserDefaults.standard.set(engineChoice.rawValue, forKey: Keys.engineChoice)
            if engineChoice == .parakeet,
               !parakeetModelChoice.supportsFluidAudioVocabulary,
               transcriptPostProcessingMode == .fluidAudioVocabulary {
                transcriptPostProcessingMode = .none
            }
        }
    }

    /// Which FluidAudio model variant to use for transcription.
    var parakeetModelChoice: ParakeetModelChoice {
        didSet {
            UserDefaults.standard.set(parakeetModelChoice.rawValue, forKey: Keys.parakeetModelChoice)
            if !parakeetModelChoice.supportsLanguage(selectedLanguage) {
                selectedLanguage = .english
            }
            if engineChoice == .parakeet,
               !parakeetModelChoice.supportsFluidAudioVocabulary,
               transcriptPostProcessingMode == .fluidAudioVocabulary {
                transcriptPostProcessingMode = .none
            }
        }
    }

    /// Whether the user has explicitly chosen an engine (vs. using the auto-default)
    var userHasChosenEngine: Bool {
        didSet {
            UserDefaults.standard.set(userHasChosenEngine, forKey: Keys.userHasChosenEngine)
        }
    }

    /// True when an existing user had the discontinued Apple Speech engine
    /// selected and still needs to download Parakeet.
    var legacyAppleSpeechMigrationPending: Bool {
        didSet {
            UserDefaults.standard.set(
                legacyAppleSpeechMigrationPending,
                forKey: Keys.legacyAppleSpeechMigrationPending
            )
        }
    }

    // MARK: - Language Settings

    var selectedLanguage: SupportedLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Keys.selectedLanguage)
        }
    }

    /// Language used by Apple's SpeechTranscriber. Kept separate so switching
    /// engines does not overwrite the user's FluidAudio language preference.
    var appleSpeechLanguage: SupportedLanguage {
        didSet {
            UserDefaults.standard.set(appleSpeechLanguage.rawValue, forKey: Keys.appleSpeechLanguage)
        }
    }

    // MARK: - Input Source Auto-Switch

    var inputSourceMappings: [InputSourceMapping] {
        didSet {
            guard let data = try? JSONEncoder().encode(inputSourceMappings) else { return }
            UserDefaults.standard.set(data, forKey: Keys.inputSourceMappings)
        }
    }

    var inputSourceAutoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(inputSourceAutoSwitchEnabled, forKey: Keys.inputSourceAutoSwitchEnabled)
        }
    }

    /// Set when an auto-switch coerced `.fluidAudioVocabulary` away because
    /// the destination model didn't support it. Consulted the next time an
    /// auto-switch lands so the mode can be restored once a vocab-capable
    /// model is active again, without clobbering a mode the user picked
    /// manually in the meantime.
    var pendingVocabularyModeRestore: Bool {
        didSet {
            UserDefaults.standard.set(pendingVocabularyModeRestore, forKey: Keys.pendingVocabularyModeRestore)
        }
    }

    /// Decodes mappings, dropping entries whose enum raw values no longer
    /// exist and parakeet entries missing a model. Also re-coerces the
    /// language against the model's capability, since a model's supported
    /// language set can change across app versions after a mapping was
    /// stored (same rule as the `parakeetModelChoice` didSet and the
    /// mutation helpers below).
    nonisolated static func sanitizedMappings(from data: Data) -> [InputSourceMapping] {
        guard let raw = try? JSONDecoder().decode([RawInputSourceMapping].self, from: data) else { return [] }
        return raw.compactMap { entry in
            guard let engine = TranscriptionEngineChoice(rawValue: entry.engine),
                  var language = SupportedLanguage(rawValue: entry.language) else { return nil }
            var model: ParakeetModelChoice?
            if let rawModel = entry.parakeetModel {
                guard let parsed = ParakeetModelChoice(rawValue: rawModel) else { return nil }
                model = parsed
            }
            if engine == .parakeet, model == nil { return nil }
            if engine == .parakeet, model?.supportsLanguage(language) == false {
                language = .english
            }
            return InputSourceMapping(
                id: entry.id,
                inputSourceID: entry.inputSourceID,
                inputSourceDisplayName: entry.inputSourceDisplayName,
                engine: engine,
                parakeetModel: model,
                language: language
            )
        }
    }

    // MARK: - Filler Word Removal

    var isFillerWordRemovalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFillerWordRemovalEnabled, forKey: Keys.isFillerWordRemovalEnabled)
        }
    }

    var fillerWordsToRemove: [String] {
        didSet {
            UserDefaults.standard.set(fillerWordsToRemove, forKey: Keys.fillerWordsToRemove)
            cachedFillerRegex = nil
        }
    }

    /// Cached compiled regex for filler word removal (invalidated when words change)
    private var cachedFillerRegex: NSRegularExpression?

    /// 唔 is deliberately absent: it is a hesitation sound in Mandarin but the
    /// standard negator in Cantonese (唔知 "don't know"), so removing it by
    /// default can invert the meaning of a transcript.
    static let defaultFillerWords = ["um", "uh", "erm", "er", "hmm", "嗯", "呃"]

    /// Han fillers safe to delete from inside continuous text.
    ///
    /// Unsegmented Han has no word boundaries for `\b` to anchor to, so a CJK
    /// filler pattern matches anywhere in the string. That is only safe for pure
    /// interjections that never form part of a word — every other Han filler a
    /// user adds is matched boundary-anchored instead, so it is removed only
    /// when standing alone. Keep this list conservative.
    static let bareMatchCJKFillers: Set<String> = ["嗯", "呃"]

    // MARK: - Transcript Post Processing

    var customVocabulary: [String] {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: Keys.customVocabulary)
        }
    }

    var transcriptPostProcessingMode: TranscriptPostProcessingMode {
        didSet {
            UserDefaults.standard.set(transcriptPostProcessingMode.rawValue, forKey: Keys.transcriptPostProcessingMode)
        }
    }

    var transcriptHistory: [TranscriptHistoryEntry] {
        didSet {
            guard let data = try? JSONEncoder().encode(transcriptHistory) else { return }
            UserDefaults.standard.set(data, forKey: Keys.transcriptHistory)
        }
    }

    var aiPostProcessingPrompt: String {
        didSet {
            UserDefaults.standard.set(aiPostProcessingPrompt, forKey: Keys.aiPostProcessingPrompt)
        }
    }

    var ollamaBaseURL: String {
        didSet {
            UserDefaults.standard.set(ollamaBaseURL, forKey: Keys.ollamaBaseURL)
        }
    }

    var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: Keys.ollamaModel)
        }
    }

    var ollamaReasoningSetting: OllamaReasoningSetting {
        didSet {
            UserDefaults.standard.set(ollamaReasoningSetting.rawValue, forKey: Keys.ollamaReasoningSetting)
        }
    }

    var ollamaPostProcessingPrompt: String {
        didSet {
            UserDefaults.standard.set(ollamaPostProcessingPrompt, forKey: Keys.ollamaPostProcessingPrompt)
        }
    }

    var openRouterModel: String {
        didSet {
            UserDefaults.standard.set(openRouterModel, forKey: Keys.openRouterModel)
        }
    }

    var openRouterPostProcessingPrompt: String {
        didSet {
            UserDefaults.standard.set(openRouterPostProcessingPrompt, forKey: Keys.openRouterPostProcessingPrompt)
        }
    }

    var openRouterAPIKey: String {
        didSet {
            Self.storeOpenRouterAPIKey(openRouterAPIKey)
        }
    }

    var openRouterAPIKeyEnvironmentVariable: String {
        didSet {
            UserDefaults.standard.set(
                openRouterAPIKeyEnvironmentVariable,
                forKey: Keys.openRouterAPIKeyEnvironmentVariable
            )
        }
    }

    var openAICompatibleBaseURL: String {
        didSet {
            UserDefaults.standard.set(openAICompatibleBaseURL, forKey: Keys.openAICompatibleBaseURL)
        }
    }

    var openAICompatibleModel: String {
        didSet {
            UserDefaults.standard.set(openAICompatibleModel, forKey: Keys.openAICompatibleModel)
        }
    }

    var openAICompatibleAPIKey: String {
        didSet {
            Self.storeOpenAICompatibleAPIKey(openAICompatibleAPIKey)
        }
    }

    var openAICompatiblePostProcessingPrompt: String {
        didSet {
            UserDefaults.standard.set(
                openAICompatiblePostProcessingPrompt,
                forKey: Keys.openAICompatiblePostProcessingPrompt
            )
        }
    }

    var fluidAudioVocabularyEnabled: Bool {
        transcriptPostProcessingMode == .fluidAudioVocabulary
    }

    var appleIntelligencePostProcessingEnabled: Bool {
        transcriptPostProcessingMode == .appleIntelligence
    }

    var ollamaPostProcessingEnabled: Bool {
        transcriptPostProcessingMode == .ollama
    }

    var openRouterPostProcessingEnabled: Bool {
        transcriptPostProcessingMode == .openRouter
    }

    var openAICompatiblePostProcessingEnabled: Bool {
        transcriptPostProcessingMode == .openAICompatible
    }

    // MARK: - Microphone Selection

    /// Selected microphone UID. nil = follow system default.
    var selectedMicrophoneUID: String? {
        didSet {
            if let uid = selectedMicrophoneUID {
                UserDefaults.standard.set(uid, forKey: Keys.selectedMicrophoneUID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedMicrophoneUID)
            }
        }
    }

    // MARK: - Recording Audio

    var boostMicrophoneVolumeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(boostMicrophoneVolumeEnabled, forKey: Keys.boostMicrophoneVolumeEnabled)
        }
    }

    var muteSystemAudioDuringRecordingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(muteSystemAudioDuringRecordingEnabled, forKey: Keys.muteSystemAudioDuringRecordingEnabled)
        }
    }

    var autoStopAfterSpeechEndsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStopAfterSpeechEndsEnabled, forKey: Keys.autoStopAfterSpeechEndsEnabled)
        }
    }

    // MARK: - Sound Effects

    var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled)
        }
    }

    var soundEffectsVolume: Float {
        didSet {
            UserDefaults.standard.set(soundEffectsVolume, forKey: Keys.soundEffectsVolume)
        }
    }

    // MARK: - Overlay Settings

    var showTextPreview: Bool {
        didSet {
            UserDefaults.standard.set(showTextPreview, forKey: Keys.showTextPreview)
        }
    }

    // MARK: - App Behavior

    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    var appAppearanceMode: AppAppearanceMode {
        didSet {
            UserDefaults.standard.set(appAppearanceMode.rawValue, forKey: Keys.appAppearanceMode)
            NotificationCenter.default.post(name: .appAppearanceModeChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults.standard

        // Hotkey bindings (with migration from legacy single-hotkey format)
        if let data = defaults.data(forKey: Keys.hotkeyBindings),
           let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data) {
            let normalized = decoded.map(Self.canonicalizedHotkeyBinding)
            hotkeyBindings = normalized
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: Keys.hotkeyBindings)
            }
        } else if defaults.object(forKey: Keys.hotkeyKeyCode) != nil
                    || defaults.object(forKey: Keys.hotkeyModifiers) != nil {
            // Migrate legacy single-hotkey properties
            let keyCode: UInt16? = (defaults.object(forKey: Keys.hotkeyKeyCode) as? Int).map { UInt16($0) }
            let modRaw = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt64 ?? 0
            let mods = Self.hotkeyModifiers(from: CGEventFlags(rawValue: modRaw))
            let name = defaults.string(forKey: Keys.hotkeyDisplayName) ?? ""
            let modeStr = defaults.string(forKey: Keys.hotkeyMode) ?? HotkeyMode.holdToRecord.rawValue
            let mode = HotkeyMode(rawValue: modeStr) ?? .holdToRecord
            let migrated = Self.canonicalizedHotkeyBinding(HotkeyBinding(
                id: UUID(), keyCode: keyCode, modifiersRawValue: mods.rawValue,
                displayName: name.isEmpty ? Self.displayName(keyCode: keyCode, modifiers: mods) : name,
                mode: mode
            ))
            let migratedBindings = [migrated]
            hotkeyBindings = migratedBindings
            // Persist in new format
            if let data = try? JSONEncoder().encode(migratedBindings) {
                defaults.set(data, forKey: Keys.hotkeyBindings)
            }
            // Clean up legacy keys
            defaults.removeObject(forKey: Keys.hotkeyKeyCode)
            defaults.removeObject(forKey: Keys.hotkeyModifiers)
            defaults.removeObject(forKey: Keys.hotkeyDisplayName)
            defaults.removeObject(forKey: Keys.hotkeyMode)
        } else {
            // Fresh install: default binding
            hotkeyBindings = [HotkeyBinding.defaultBinding]
        }

        // Engine
        let hasChosenEngine = defaults.object(forKey: Keys.userHasChosenEngine) as? Bool ?? false
        userHasChosenEngine = hasChosenEngine
        let storedEngineRaw = defaults.string(forKey: Keys.engineChoice)
        let hadDiscontinuedAppleSpeech = storedEngineRaw == "appleSpeech" && !AppleSpeechEngine.isSupported
        let previouslyPendingMigration = defaults.object(forKey: Keys.legacyAppleSpeechMigrationPending) as? Bool ?? false
        let persistedParakeetModelChoice = ParakeetModelChoice(
            rawValue: defaults.string(forKey: Keys.parakeetModelChoice) ?? ""
        ) ?? .multilingual
        var persistedEngineChoice = TranscriptionEngineChoice(rawValue: storedEngineRaw ?? "") ?? .parakeet
        if persistedEngineChoice == .appleSpeech, !AppleSpeechEngine.isSupported {
            persistedEngineChoice = .parakeet
            defaults.set(TranscriptionEngineChoice.parakeet.rawValue, forKey: Keys.engineChoice)
        }
        engineChoice = persistedEngineChoice
        parakeetModelChoice = persistedParakeetModelChoice
        if hadDiscontinuedAppleSpeech {
            userHasChosenEngine = false
        }
        // Apply auto-default before first render to avoid transient startup mismatch.
        let parakeetExistsOnDisk = Self.parakeetModelExistsOnDisk()
        if !hasChosenEngine, parakeetExistsOnDisk {
            engineChoice = .parakeet
        }
        legacyAppleSpeechMigrationPending = !AppleSpeechEngine.isSupported
            && (hadDiscontinuedAppleSpeech || previouslyPendingMigration)
            && !parakeetExistsOnDisk

        // Language
        let langCode = defaults.string(forKey: Keys.selectedLanguage) ?? "en"
        selectedLanguage = SupportedLanguage(rawValue: langCode) ?? .english
        let appleLangCode = defaults.string(forKey: Keys.appleSpeechLanguage) ?? "en"
        appleSpeechLanguage = SupportedLanguage(rawValue: appleLangCode) ?? .english

        // Input source auto-switching
        if let mappingData = defaults.data(forKey: Keys.inputSourceMappings) {
            inputSourceMappings = Self.sanitizedMappings(from: mappingData)
        } else {
            inputSourceMappings = []
        }
        inputSourceAutoSwitchEnabled = defaults.object(forKey: Keys.inputSourceAutoSwitchEnabled) as? Bool ?? false
        pendingVocabularyModeRestore = defaults.object(forKey: Keys.pendingVocabularyModeRestore) as? Bool ?? false

        // Filler words
        isFillerWordRemovalEnabled = defaults.object(forKey: Keys.isFillerWordRemovalEnabled) as? Bool ?? false
        fillerWordsToRemove = defaults.object(forKey: Keys.fillerWordsToRemove) as? [String] ?? Self.defaultFillerWords

        // Custom Vocabulary
        customVocabulary = defaults.object(forKey: Keys.customVocabulary) as? [String] ?? []

        if let historyData = defaults.data(forKey: Keys.transcriptHistory),
           let decodedHistory = try? JSONDecoder().decode([TranscriptHistoryEntry].self, from: historyData) {
            let cappedHistory = Self.cappedTranscriptHistory(decodedHistory)
            transcriptHistory = cappedHistory
            if cappedHistory != decodedHistory,
               let data = try? JSONEncoder().encode(cappedHistory) {
                defaults.set(data, forKey: Keys.transcriptHistory)
            }
        } else {
            transcriptHistory = []
        }

        // Transcript Post Processing
        if let storedModeRaw = defaults.string(forKey: Keys.transcriptPostProcessingMode),
           let storedMode = TranscriptPostProcessingMode(rawValue: storedModeRaw) {
            transcriptPostProcessingMode = storedMode
        } else {
            let aiEnabled = defaults.object(forKey: Keys.aiPostProcessingEnabled) as? Bool ?? false
            let migratedMode: TranscriptPostProcessingMode = aiEnabled ? .appleIntelligence : .none
            transcriptPostProcessingMode = migratedMode
            defaults.set(migratedMode.rawValue, forKey: Keys.transcriptPostProcessingMode)
        }
        aiPostProcessingPrompt = defaults.string(forKey: Keys.aiPostProcessingPrompt) ?? ""
        ollamaBaseURL = defaults.string(forKey: Keys.ollamaBaseURL) ?? OllamaPostProcessingService.defaultBaseURL
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? ""
        ollamaReasoningSetting = OllamaReasoningSetting(
            rawValue: defaults.string(forKey: Keys.ollamaReasoningSetting) ?? ""
        ) ?? .disabled
        ollamaPostProcessingPrompt = defaults.string(forKey: Keys.ollamaPostProcessingPrompt)
            ?? Self.recommendedTranscriptCleanupPrompt
        let storedOpenRouterAPIKey = Self.storedOpenRouterAPIKey()
        openRouterAPIKey = storedOpenRouterAPIKey
        openRouterModel = defaults.string(forKey: Keys.openRouterModel) ?? ""
        openRouterPostProcessingPrompt = defaults.string(forKey: Keys.openRouterPostProcessingPrompt)
            ?? Self.recommendedTranscriptCleanupPrompt
        let storedOpenRouterCredentialHint = defaults.string(forKey: Keys.openRouterAPIKeyEnvironmentVariable)
            ?? OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable
        if storedOpenRouterAPIKey.isEmpty,
           Self.looksLikeOpenRouterAPIKey(storedOpenRouterCredentialHint) {
            openRouterAPIKey = storedOpenRouterCredentialHint
            openRouterAPIKeyEnvironmentVariable = OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable
            defaults.set(
                OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable,
                forKey: Keys.openRouterAPIKeyEnvironmentVariable
            )
        } else {
            openRouterAPIKeyEnvironmentVariable = storedOpenRouterCredentialHint
        }
        openAICompatibleBaseURL = defaults.string(forKey: Keys.openAICompatibleBaseURL)
            ?? OpenAICompatiblePostProcessingService.defaultBaseURL
        openAICompatibleModel = defaults.string(forKey: Keys.openAICompatibleModel) ?? ""
        openAICompatibleAPIKey = Self.storedOpenAICompatibleAPIKey()
        openAICompatiblePostProcessingPrompt = defaults.string(forKey: Keys.openAICompatiblePostProcessingPrompt)
            ?? Self.recommendedTranscriptCleanupPrompt

        // Microphone selection
        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID)

        // Microphone boost (default: on)
        boostMicrophoneVolumeEnabled = defaults.object(forKey: Keys.boostMicrophoneVolumeEnabled) as? Bool ?? true

        // Recording audio handling (with migration from legacy auto-volume setting).
        if let storedValue = defaults.object(forKey: Keys.muteSystemAudioDuringRecordingEnabled) as? Bool {
            muteSystemAudioDuringRecordingEnabled = storedValue
        } else {
            let migratedValue = defaults.object(forKey: Keys.legacyAutoVolumeEnabled) as? Bool ?? false
            muteSystemAudioDuringRecordingEnabled = migratedValue
            defaults.set(migratedValue, forKey: Keys.muteSystemAudioDuringRecordingEnabled)
        }
        autoStopAfterSpeechEndsEnabled = defaults.object(forKey: Keys.autoStopAfterSpeechEndsEnabled) as? Bool ?? false

        // Sound
        soundEffectsEnabled = defaults.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true
        soundEffectsVolume = defaults.object(forKey: Keys.soundEffectsVolume) as? Float ?? 0.3

        // Overlay
        showTextPreview = defaults.object(forKey: Keys.showTextPreview) as? Bool ?? true

        // App behavior
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        let appearStr = defaults.string(forKey: Keys.appAppearanceMode) ?? AppAppearanceMode.menuBarOnly.rawValue
        appAppearanceMode = AppAppearanceMode(rawValue: appearStr) ?? .menuBarOnly

        // Mandarin model coercion: reading `self` properties requires all stored
        // properties to be initialized first, so these run last even though they
        // logically belong with the language/post-processing decoding above.
        // A stored selection can outlive the hardware that could run it — a
        // migration from an Apple Silicon Mac carries the preference across.
        // Coerce in memory only, so the stored choice still applies if the same
        // home directory later lands back on a Mac with a Neural Engine.
        var effectiveParakeetModelChoice = persistedParakeetModelChoice
        if !effectiveParakeetModelChoice.isAvailableOnThisMac {
            effectiveParakeetModelChoice = ParakeetModelChoice.availableFallback(for: selectedLanguage)
            parakeetModelChoice = effectiveParakeetModelChoice
        }
        if !effectiveParakeetModelChoice.supportsLanguage(selectedLanguage) {
            selectedLanguage = .english
        }
        if engineChoice == .parakeet,
           !effectiveParakeetModelChoice.supportsFluidAudioVocabulary,
           transcriptPostProcessingMode == .fluidAudioVocabulary {
            transcriptPostProcessingMode = .none
        }

        updateLoginItem()
    }

    // MARK: - Methods

    /// Plays a sound effect if enabled
    func playSound(_ name: String) {
        guard soundEffectsEnabled else { return }
        let volume = soundEffectsVolume
        soundQueue.async {
            guard let sound = NSSound(named: name) else { return }
            sound.volume = volume
            sound.play()
        }
    }

    /// Adds a new empty hotkey binding
    func addBinding() -> HotkeyBinding {
        let binding = HotkeyBinding(
            id: UUID(), keyCode: nil, modifiersRawValue: 0,
            displayName: "", mode: .holdToRecord
        )
        hotkeyBindings.append(binding)
        return binding
    }

    /// Updates an existing binding by ID
    func updateBinding(_ binding: HotkeyBinding) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == binding.id }) else { return }
        hotkeyBindings[index] = Self.canonicalizedHotkeyBinding(binding)
    }

    /// Updates a binding's key combo
    func updateBindingHotkey(id: UUID, keyCode: UInt16?, modifiers: HotkeyModifiers, displayName: String) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == id }) else { return }
        let normalizedModifiers = Self.normalizedHotkeyModifiers(modifiers)
        var updated = hotkeyBindings[index]
        updated.keyCode = keyCode
        updated.modifiersRawValue = normalizedModifiers.rawValue
        updated.displayName = displayName.isEmpty
            ? Self.displayName(keyCode: keyCode, modifiers: normalizedModifiers)
            : displayName
        hotkeyBindings[index] = Self.canonicalizedHotkeyBinding(updated)
    }

    /// Clears a binding's key combo (keeps the row)
    func clearBindingHotkey(id: UUID) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == id }) else { return }
        hotkeyBindings[index].keyCode = nil
        hotkeyBindings[index].modifiersRawValue = 0
        hotkeyBindings[index].displayName = ""
    }

    /// Removes a binding entirely
    func removeBinding(id: UUID) {
        hotkeyBindings.removeAll { $0.id == id }
    }

    // MARK: - Input Source Mapping Helpers

    /// Adds a mapping for a not-yet-mapped input source, deriving sensible
    /// defaults. `isModelDownloaded` is injected because on-disk state lives
    /// in ParakeetEngine; auto-picking a model must never imply a download.
    @discardableResult
    func addInputSourceMapping(
        inputSourceID: String,
        displayName: String,
        derivedLanguage: SupportedLanguage?,
        isModelDownloaded: (ParakeetModelChoice) -> Bool
    ) -> InputSourceMapping? {
        guard !inputSourceMappings.contains(where: { $0.inputSourceID == inputSourceID }) else { return nil }
        let engine = engineChoice
        var language = derivedLanguage ?? (engine == .appleSpeech ? appleSpeechLanguage : selectedLanguage)
        var model: ParakeetModelChoice?
        if engine == .parakeet {
            if let derived = derivedLanguage,
               !parakeetModelChoice.supportsLanguage(derived),
               let downloaded = ParakeetModelChoice.allCases.first(where: {
                   $0.supportsLanguage(derived) && isModelDownloaded($0)
               }) {
                model = downloaded
            } else {
                model = parakeetModelChoice
            }
            if let chosen = model, !chosen.supportsLanguage(language) {
                language = .english
            }
        }
        let mapping = InputSourceMapping(
            id: UUID(),
            inputSourceID: inputSourceID,
            inputSourceDisplayName: displayName,
            engine: engine,
            parakeetModel: model,
            language: language
        )
        inputSourceMappings.append(mapping)
        return mapping
    }

    /// Replaces a mapping by ID, normalizing model/language so every stored
    /// mapping satisfies the capability rules. Apple Speech language
    /// availability is validated at apply time (the authority is
    /// AppleSpeechEngine, which Settings cannot query synchronously).
    func updateInputSourceMapping(_ mapping: InputSourceMapping) {
        guard let index = inputSourceMappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        guard !inputSourceMappings.contains(where: {
            $0.id != mapping.id && $0.inputSourceID == mapping.inputSourceID
        }) else { return }
        var updated = mapping
        switch updated.engine {
        case .appleSpeech:
            updated.parakeetModel = nil
        case .parakeet:
            let model = updated.parakeetModel ?? parakeetModelChoice
            updated.parakeetModel = model
            if !model.supportsLanguage(updated.language) {
                updated.language = .english
            }
        }
        inputSourceMappings[index] = updated
    }

    func removeInputSourceMapping(id: UUID) {
        inputSourceMappings.removeAll { $0.id == id }
    }

    func mapping(forInputSourceID id: String) -> InputSourceMapping? {
        inputSourceMappings.first { $0.inputSourceID == id }
    }

    /// Call right after an auto-switch may have driven the `parakeetModelChoice`
    /// or `engineChoice` didSet coercion that strips `.fluidAudioVocabulary`.
    /// `hadVocabularyMode` is the mode captured *before* that write. Sets the
    /// pending-restore flag only when the coercion actually fired.
    func noteAutoSwitchModelChange(hadVocabularyMode: Bool) {
        guard hadVocabularyMode, transcriptPostProcessingMode != .fluidAudioVocabulary else { return }
        pendingVocabularyModeRestore = true
    }

    /// Call after every auto-switch resolution (including no-ops) so a
    /// pending restore lands as soon as a vocab-capable Parakeet model is
    /// active again, without overriding a mode the user picked manually in
    /// the meantime.
    func restoreVocabularyModeAfterAutoSwitchIfPending() {
        guard pendingVocabularyModeRestore else { return }

        if transcriptPostProcessingMode == .fluidAudioVocabulary {
            pendingVocabularyModeRestore = false
        } else if transcriptPostProcessingMode != .none {
            pendingVocabularyModeRestore = false
        } else if engineChoice == .parakeet, parakeetModelChoice.supportsFluidAudioVocabulary {
            transcriptPostProcessingMode = .fluidAudioVocabulary
            pendingVocabularyModeRestore = false
        }
    }

    func addTranscriptHistoryEntry(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        transcriptHistory = Self.cappedTranscriptHistory(transcriptHistory + [TranscriptHistoryEntry(
            id: UUID(),
            text: trimmedText,
            createdAt: Date()
        )])
    }

    func removeTranscriptHistoryEntry(id: UUID) {
        transcriptHistory.removeAll { $0.id == id }
    }

    func clearTranscriptHistory() {
        transcriptHistory = []
    }

    private static func cappedTranscriptHistory(_ history: [TranscriptHistoryEntry]) -> [TranscriptHistoryEntry] {
        let maxEntries = 50
        guard history.count > maxEntries else { return history }
        return Array(history.suffix(maxEntries))
    }

    // MARK: - Login Item

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }

    // MARK: - Filler Word Removal

    func removeFillerWords(from text: String) -> String {
        guard isFillerWordRemovalEnabled, !fillerWordsToRemove.isEmpty else { return text }

        let regex: NSRegularExpression
        if let cached = cachedFillerRegex {
            regex = cached
        } else {
            let alternatives = fillerWordsToRemove.compactMap { word -> String? in
                let trimmed = word.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let escaped = NSRegularExpression.escapedPattern(for: trimmed)
                // \b is meaningless inside unsegmented Han text, so Han fillers
                // cannot anchor on it. A curated pure interjection matches bare,
                // with a trailing + to collapse stutters (嗯嗯). Every other Han
                // filler is boundary-anchored so it is only removed when
                // standing alone — a word-forming character such as the
                // Cantonese negator 唔 must never be cut out of running text.
                if trimmed.unicodeScalars.contains(where: { CJKText.isCJK($0) }) {
                    let repeated = "(?:\(escaped))+"
                    guard Self.bareMatchCJKFillers.contains(trimmed) else {
                        return "(?<![^\\s\\p{P}])\(repeated)(?![^\\s\\p{P}])"
                    }
                    return repeated
                }
                return "\\b\(escaped)\\b"
            }
            guard !alternatives.isEmpty else { return text }

            let pattern = "(?:" + alternatives.joined(separator: "|") + ")"
            do {
                let compiled = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                cachedFillerRegex = compiled
                regex = compiled
            } catch {
                return text
            }
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " \u{FF0C}", with: "\u{FF0C}")   // ，
        result = result.replacingOccurrences(of: " \u{3002}", with: "\u{3002}")   // 。
        result = result.replacingOccurrences(of: " \u{FF01}", with: "\u{FF01}")   // ！
        result = result.replacingOccurrences(of: " \u{FF1F}", with: "\u{FF1F}")   // ？
        while result.contains("\u{FF0C}\u{FF0C}") {
            result = result.replacingOccurrences(of: "\u{FF0C}\u{FF0C}", with: "\u{FF0C}")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Key Name Utilities

    nonisolated static func keyName(for keyCode: UInt16) -> String {
        let keyNames: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".",
            36: "\u{21A9}", 48: "\u{21E5}", 49: "Space", 51: "\u{232B}", 53: "\u{238B}",
            76: "\u{2305}",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 114: "Help", 115: "\u{2196}", 116: "\u{21DE}",
            117: "\u{2326}", 118: "F4", 119: "\u{2198}", 120: "F2", 121: "\u{21DF}",
            122: "F1", 123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
            54: "R\u{2318}", 55: "L\u{2318}",
            58: "L\u{2325}", 61: "R\u{2325}",
            59: "L\u{2303}", 62: "R\u{2303}",
            56: "L\u{21E7}", 60: "R\u{21E7}",
            63: "fn",
            179: "fn",
        ]
        return keyNames[keyCode] ?? "Key\(keyCode)"
    }

    /// Builds a display name from modifier profile + key code
    nonisolated static func displayName(keyCode: UInt16?, modifiers: HotkeyModifiers) -> String {
        let normalizedModifiers = normalizedHotkeyModifiers(modifiers)
        var parts: [String] = []
        if normalizedModifiers.contains(.function) { parts.append("fn") }
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .control,
            left: .leftControl,
            right: .rightControl,
            symbol: "\u{2303}"
        )
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .option,
            left: .leftOption,
            right: .rightOption,
            symbol: "\u{2325}"
        )
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .shift,
            left: .leftShift,
            right: .rightShift,
            symbol: "\u{21E7}"
        )
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .command,
            left: .leftCommand,
            right: .rightCommand,
            symbol: "\u{2318}"
        )
        if let keyCode {
            let key = keyName(for: keyCode)
            // Avoid rendering duplicate "fn" when a legacy binding stores fn as keyCode.
            if !(normalizedModifiers.contains(.function) && key.lowercased() == "fn") {
                parts.append(key)
            }
        }
        return parts.joined()
    }

    private static func parakeetModelExistsOnDisk() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        return ParakeetModelChoice.allCases.contains {
            FileManager.default.fileExists(atPath: path.appendingPathComponent($0.modelDirectoryName).path)
        }
    }

    nonisolated static func normalizedModifierFlags(_ modifiers: CGEventFlags) -> CGEventFlags {
        cgEventFlags(from: hotkeyModifiers(from: modifiers))
    }

    nonisolated static func hotkeyModifiers(from flags: CGEventFlags) -> HotkeyModifiers {
        var modifiers = HotkeyModifiers()
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }

        let raw = flags.rawValue
        if raw & HotkeyModifiers.leftCommand.rawValue != 0 { modifiers.insert(.leftCommand) }
        if raw & HotkeyModifiers.rightCommand.rawValue != 0 { modifiers.insert(.rightCommand) }
        if raw & HotkeyModifiers.leftControl.rawValue != 0 { modifiers.insert(.leftControl) }
        if raw & HotkeyModifiers.rightControl.rawValue != 0 { modifiers.insert(.rightControl) }
        if raw & HotkeyModifiers.leftOption.rawValue != 0 { modifiers.insert(.leftOption) }
        if raw & HotkeyModifiers.rightOption.rawValue != 0 { modifiers.insert(.rightOption) }
        if raw & HotkeyModifiers.leftShift.rawValue != 0 { modifiers.insert(.leftShift) }
        if raw & HotkeyModifiers.rightShift.rawValue != 0 { modifiers.insert(.rightShift) }
        return normalizedHotkeyModifiers(modifiers)
    }

    nonisolated static func normalizedHotkeyModifiers(_ modifiers: HotkeyModifiers) -> HotkeyModifiers {
        var normalized = modifiers.intersection(.relevant)
        if normalized.intersection([.leftCommand, .rightCommand]).isEmpty == false {
            normalized.insert(.command)
        }
        if normalized.intersection([.leftControl, .rightControl]).isEmpty == false {
            normalized.insert(.control)
        }
        if normalized.intersection([.leftOption, .rightOption]).isEmpty == false {
            normalized.insert(.option)
        }
        if normalized.intersection([.leftShift, .rightShift]).isEmpty == false {
            normalized.insert(.shift)
        }
        return normalized
    }

    nonisolated static func deviceIndependentModifiers(from modifiers: HotkeyModifiers) -> HotkeyModifiers {
        let normalized = normalizedHotkeyModifiers(modifiers)
        var broad: HotkeyModifiers = []
        if normalized.contains(.command) { broad.insert(.command) }
        if normalized.contains(.control) { broad.insert(.control) }
        if normalized.contains(.option) { broad.insert(.option) }
        if normalized.contains(.shift) { broad.insert(.shift) }
        if normalized.contains(.function) { broad.insert(.function) }
        return broad
    }

    nonisolated static func cgEventFlags(from modifiers: HotkeyModifiers) -> CGEventFlags {
        let broad = deviceIndependentModifiers(from: modifiers)
        var flags = CGEventFlags(rawValue: 0)
        if broad.contains(.command) { flags.insert(.maskCommand) }
        if broad.contains(.control) { flags.insert(.maskControl) }
        if broad.contains(.option) { flags.insert(.maskAlternate) }
        if broad.contains(.shift) { flags.insert(.maskShift) }
        if broad.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    nonisolated static func keyedModifiersMatch(event: HotkeyModifiers, target: HotkeyModifiers) -> Bool {
        let normalizedEvent = normalizedHotkeyModifiers(event)
        let normalizedTarget = normalizedHotkeyModifiers(target)
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .command, left: .leftCommand, right: .rightCommand, exact: false) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .control, left: .leftControl, right: .rightControl, exact: false) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .option, left: .leftOption, right: .rightOption, exact: false) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .shift, left: .leftShift, right: .rightShift, exact: false) else { return false }
        if normalizedTarget.contains(.function) && !normalizedEvent.contains(.function) { return false }
        return true
    }

    nonisolated static func modifierOnlyModifiersMatch(event: HotkeyModifiers, target: HotkeyModifiers) -> Bool {
        let normalizedEvent = normalizedHotkeyModifiers(event)
        let normalizedTarget = normalizedHotkeyModifiers(target)
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .command, left: .leftCommand, right: .rightCommand, exact: true) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .control, left: .leftControl, right: .rightControl, exact: true) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .option, left: .leftOption, right: .rightOption, exact: true) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .shift, left: .leftShift, right: .rightShift, exact: true) else { return false }
        if normalizedTarget.contains(.function) != normalizedEvent.contains(.function) { return false }
        return true
    }

    private nonisolated static func canonicalizedHotkeyBinding(_ binding: HotkeyBinding) -> HotkeyBinding {
        var normalized = binding
        let hadCapsKey = normalized.keyCode == 57
        let hadCapsModifier = HotkeyModifiers(rawValue: normalized.modifiersRawValue).contains(.capsLock)
        if hadCapsKey || hadCapsModifier {
            normalized.keyCode = nil
            normalized.modifiersRawValue = 0
            normalized.displayName = ""
            return normalized
        }

        if let keyCode = normalized.keyCode, functionKeyCodes.contains(keyCode) {
            var modifiers = normalized.modifiers
            modifiers.insert(.function)
            normalized.keyCode = nil
            normalized.modifiers = modifiers
            normalized.displayName = displayName(keyCode: nil, modifiers: modifiers)
            return normalized
        }

        let modifiers = normalizedHotkeyModifiers(HotkeyModifiers(rawValue: normalized.modifiersRawValue))
        normalized.modifiersRawValue = modifiers.rawValue
        normalized.displayName = normalized.keyCode == nil && modifiers.isEmpty
            ? ""
            : displayName(keyCode: normalized.keyCode, modifiers: modifiers)
        return normalized
    }

    private nonisolated static func appendSideAware(
        parts: inout [String],
        modifiers: HotkeyModifiers,
        any: HotkeyModifiers,
        left: HotkeyModifiers,
        right: HotkeyModifiers,
        symbol: String
    ) {
        let hasLeft = modifiers.contains(left)
        let hasRight = modifiers.contains(right)
        if hasLeft { parts.append("L\(symbol)") }
        if hasRight { parts.append("R\(symbol)") }
        if !hasLeft && !hasRight && modifiers.contains(any) { parts.append(symbol) }
    }

    private nonisolated static func groupMatch(
        event: HotkeyModifiers,
        target: HotkeyModifiers,
        any: HotkeyModifiers,
        left: HotkeyModifiers,
        right: HotkeyModifiers,
        exact: Bool
    ) -> Bool {
        let targetAny = target.contains(any)
        let targetLeft = target.contains(left)
        let targetRight = target.contains(right)
        let eventAny = event.contains(any)
        let eventLeft = event.contains(left)
        let eventRight = event.contains(right)

        if !targetAny && !targetLeft && !targetRight {
            return exact ? (!eventAny && !eventLeft && !eventRight) : true
        }

        if targetLeft || targetRight {
            if targetLeft && !eventLeft { return false }
            if targetRight && !eventRight { return false }
            if !eventAny { return false }
            if exact {
                if !targetLeft && eventLeft { return false }
                if !targetRight && eventRight { return false }
            }
            return true
        }

        return eventAny
    }

    private nonisolated static var openRouterAPIKeyKeychainService: String {
        (Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere") + ".openrouter"
    }

    private nonisolated static func storedOpenRouterAPIKey() -> String {
        KeychainSecretStore.read(
            service: openRouterAPIKeyKeychainService,
            account: openRouterAPIKeyKeychainAccount
        )
    }

    private nonisolated static func storeOpenRouterAPIKey(_ value: String) {
        KeychainSecretStore.write(
            value,
            service: openRouterAPIKeyKeychainService,
            account: openRouterAPIKeyKeychainAccount
        )
    }

    private nonisolated static var openAICompatibleAPIKeyKeychainService: String {
        (Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere") + ".openai-compatible"
    }

    private nonisolated static func storedOpenAICompatibleAPIKey() -> String {
        KeychainSecretStore.read(
            service: openAICompatibleAPIKeyKeychainService,
            account: openAICompatibleAPIKeyKeychainAccount
        )
    }

    private nonisolated static func storeOpenAICompatibleAPIKey(_ value: String) {
        KeychainSecretStore.write(
            value,
            service: openAICompatibleAPIKeyKeychainService,
            account: openAICompatibleAPIKeyKeychainAccount
        )
    }

    private nonisolated static func looksLikeOpenRouterAPIKey(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-or-")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let appAppearanceModeChanged = Notification.Name("appAppearanceModeChanged")
}
