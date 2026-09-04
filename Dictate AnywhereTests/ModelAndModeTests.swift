import XCTest
import FluidAudio
@testable import Dictate_Anywhere

final class ModelAndModeTests: XCTestCase {

    // MARK: - Architecture-aware availability

    /// The capability flag must equal `#if arch(arm64)` in *both* directions.
    ///
    /// Upward: an arm64 run reporting "no Neural Engine" would hide working
    /// models from every user, and would be invisible in CI.
    /// Downward: the x86_64 slice of our universal binary can be running under
    /// Rosetta on Apple Silicon, where the host *does* have a Neural Engine but
    /// FluidAudio still refuses to load its ANE-only models. A runtime probe
    /// (`hw.optional.arm64` / `sysctl.proc_translated`) answers true there, so
    /// this test is what stops one from creeping back in.
    func testNeuralEngineCapabilityMatchesCompileTimeArchitecture() {
        #if arch(arm64)
        XCTAssertTrue(Hardware.isArm64Process, "arm64 slice must report an arm64 process")
        XCTAssertTrue(Hardware.canUseAppleNeuralEngine, "arm64 build must be able to use the ANE")
        #else
        XCTAssertFalse(Hardware.isArm64Process, "non-arm64 slice must not report an arm64 process")
        XCTAssertFalse(
            Hardware.canUseAppleNeuralEngine,
            "a non-arm64 slice must be treated as ANE-incapable even under Rosetta on Apple Silicon")
        #endif
        XCTAssertEqual(Hardware.canUseAppleNeuralEngine, Hardware.isArm64Process)
    }

    /// Pins our gate to the one FluidAudio actually enforces: both Nemotron
    /// multilingual entry points do
    /// `guard SystemInfo.isAppleSilicon else { throw ASRError.unsupportedPlatform }`.
    /// If FluidAudio ever changes that rule, this fails instead of users
    /// downloading ~650 MB for a model that cannot load.
    func testNeuralEngineCapabilityMatchesFluidAudioPlatformGate() {
        XCTAssertEqual(
            Hardware.canUseAppleNeuralEngine,
            SystemInfo.isAppleSilicon,
            "capability must match FluidAudio's own unsupportedPlatform guard")
    }

    /// Nemotron multilingual is offered exactly when this process slice can run
    /// it — never on x86_64, whatever hardware is underneath.
    func testNemotronMultilingualAvailabilityTracksCompileTimeArchitecture() {
        #if arch(arm64)
        XCTAssertTrue(ParakeetModelChoice.nemotronMultilingual.isAvailableOnThisMac)
        XCTAssertTrue(ParakeetModelChoice.availableCases.contains(.nemotronMultilingual))
        #else
        XCTAssertFalse(
            ParakeetModelChoice.nemotronMultilingual.isAvailableOnThisMac,
            "Rosetta/Intel slice must not offer the ANE-only model")
        XCTAssertFalse(ParakeetModelChoice.availableCases.contains(.nemotronMultilingual))
        XCTAssertEqual(
            ParakeetModelChoice.availableFallback(for: .chinese), .senseVoice,
            "Chinese must fall back to SenseVoice's fp32 build off arm64")
        #endif
        XCTAssertEqual(
            ParakeetModelChoice.availableCases.contains(.nemotronMultilingual),
            Hardware.canUseAppleNeuralEngine)
    }

    /// Nemotron multilingual ships only an ANE-targeted int8 encoder
    /// ("Apple Silicon only" per FluidAudio), so it is the one model with no
    /// non-ANE code path. Everything else must stay available on Intel.
    func testOnlyNemotronMultilingualRequiresAppleNeuralEngine() {
        for choice in ParakeetModelChoice.allCases {
            XCTAssertEqual(
                choice.requiresAppleNeuralEngine,
                choice == .nemotronMultilingual,
                "\(choice) has the wrong Neural Engine requirement")
        }
    }

    /// SenseVoice falls back to the fp32 encoder rather than being hidden.
    func testSenseVoiceStaysAvailableWithoutNeuralEngine() {
        XCTAssertFalse(ParakeetModelChoice.senseVoice.requiresAppleNeuralEngine)
        XCTAssertTrue(ParakeetModelChoice.senseVoice.isAvailableOnThisMac)
    }

    func testAvailableCasesExcludeModelsThisMacCannotRun() {
        XCTAssertEqual(
            ParakeetModelChoice.availableCases,
            ParakeetModelChoice.allCases.filter(\.isAvailableOnThisMac))
        for choice in ParakeetModelChoice.availableCases {
            XCTAssertTrue(choice.isAvailableOnThisMac, "\(choice) offered but not runnable")
        }
        XCTAssertEqual(
            ParakeetModelChoice.availableCases.contains(.nemotronMultilingual),
            Hardware.canUseAppleNeuralEngine,
            "nemotronMultilingual availability must track the Neural Engine")
    }

    /// The picker must never be empty, whatever the hardware.
    func testAvailableCasesAreNeverEmpty() {
        XCTAssertFalse(ParakeetModelChoice.availableCases.isEmpty)
    }

    func testAvailableFallbackIsRunnableAndPrefersLanguageSupport() {
        for language in SupportedLanguage.allCases {
            let fallback = ParakeetModelChoice.availableFallback(for: language)
            XCTAssertTrue(fallback.isAvailableOnThisMac, "fallback for \(language) is not runnable")
            if ParakeetModelChoice.availableCases.contains(where: { $0.supportsLanguage(language) }) {
                XCTAssertTrue(
                    fallback.supportsLanguage(language),
                    "fallback for \(language) dropped language support unnecessarily")
            }
        }
    }

    /// Chinese must keep working on Intel, where nemotronMultilingual is gone
    /// but SenseVoice's fp32 build still runs.
    func testChineseFallbackResolvesToSenseVoice() {
        XCTAssertEqual(ParakeetModelChoice.availableFallback(for: .chinese), .senseVoice)
    }

    // MARK: - Intel behavior (simulated — CI runs on Apple Silicon)

    func testIntelPickerHidesNemotronMultilingualAndKeepsEverythingElse() {
        let intel = ParakeetModelChoice.availableCases(hasNeuralEngine: false)
        XCTAssertFalse(intel.contains(.nemotronMultilingual), "Nemotron multilingual cannot run on Intel")
        XCTAssertEqual(intel, ParakeetModelChoice.allCases.filter { $0 != .nemotronMultilingual },
                       "only the ANE-only model should be withheld on Intel")
    }

    func testAppleSiliconPickerOffersEveryModel() {
        XCTAssertEqual(
            ParakeetModelChoice.availableCases(hasNeuralEngine: true),
            ParakeetModelChoice.allCases)
    }

    /// A Mac migrated from Apple Silicon can hold a nemotronMultilingual
    /// selection Intel can't run; Chinese users must land on SenseVoice rather
    /// than silently losing Chinese support.
    func testIntelFallbackKeepsChineseOnSenseVoice() {
        XCTAssertEqual(
            ParakeetModelChoice.availableFallback(for: .chinese, hasNeuralEngine: false),
            .senseVoice)
    }

    func testIntelFallbackIsRunnableForEveryLanguage() {
        for language in SupportedLanguage.allCases {
            let fallback = ParakeetModelChoice.availableFallback(for: language, hasNeuralEngine: false)
            XCTAssertNotEqual(fallback, .nemotronMultilingual, "\(language) fell back to an Intel-incapable model")
            XCTAssertTrue(fallback.isAvailable(hasNeuralEngine: false))
            XCTAssertTrue(fallback.supportsLanguage(language), "\(language) lost language support on Intel")
        }
    }

    /// fp16/int8 SenseVoice encoders emit NaN off the ANE, so non-ANE Macs must
    /// load the fp32 build instead.
    func testSenseVoicePrecisionTracksNeuralEngineAvailability() {
        XCTAssertEqual(
            ParakeetEngine.senseVoiceEncoderPrecision,
            Hardware.canUseAppleNeuralEngine ? SenseVoiceEncoderPrecision.int8 : .fp32)
    }

    // MARK: - ParakeetModelChoice

    func testAllModelChoicesHaveMetadata() {
        for choice in ParakeetModelChoice.allCases {
            XCTAssertFalse(choice.displayName.isEmpty, "\(choice) missing displayName")
            XCTAssertFalse(choice.detail.isEmpty, "\(choice) missing detail")
            XCTAssertFalse(choice.sizeSummary.isEmpty, "\(choice) missing sizeSummary")
            XCTAssertFalse(choice.languageSummary.isEmpty, "\(choice) missing languageSummary")
        }
    }

    func testModelChoiceLanguageSummaryMatchesEnglishOnlyFlag() {
        for choice in ParakeetModelChoice.allCases {
            if choice.isEnglishOnly {
                XCTAssertEqual(choice.languageSummary, "English only")
            } else {
                XCTAssertNotEqual(choice.languageSummary, "English only")
            }
        }
    }

    func testMultilingualIsNotEnglishOnly() {
        XCTAssertFalse(ParakeetModelChoice.multilingual.isEnglishOnly)
        XCTAssertTrue(ParakeetModelChoice.englishOnly.isEnglishOnly)
    }

    func testStreamingModelsUseTrueStreaming() {
        XCTAssertTrue(ParakeetModelChoice.nemotron2240.usesTrueStreaming)
        XCTAssertFalse(ParakeetModelChoice.multilingual.usesTrueStreaming)
    }

    func testModelChoiceRawValuesRoundTrip() {
        for choice in ParakeetModelChoice.allCases {
            XCTAssertEqual(ParakeetModelChoice(rawValue: choice.rawValue), choice)
        }
    }

    // MARK: - TranscriptionEngineChoice

    func testEngineDisplayName() {
        XCTAssertEqual(TranscriptionEngineChoice.parakeet.displayName, "FluidAudio")
        XCTAssertEqual(TranscriptionEngineChoice.appleSpeech.displayName, "Apple Speech")
    }

    func testEngineChoicesHaveMetadataAndStableRawValues() {
        XCTAssertEqual(TranscriptionEngineChoice.allCases, [.parakeet, .appleSpeech])
        for choice in TranscriptionEngineChoice.allCases {
            XCTAssertFalse(choice.displayName.isEmpty)
            XCTAssertFalse(choice.detail.isEmpty)
            XCTAssertEqual(TranscriptionEngineChoice(rawValue: choice.rawValue), choice)
        }
    }

    // MARK: - TranscriptPostProcessingMode

    func testPostProcessingModeDisplayNames() {
        XCTAssertEqual(TranscriptPostProcessingMode.none.displayName, "None")
        XCTAssertEqual(TranscriptPostProcessingMode.fluidAudioVocabulary.displayName, "FluidAudio Vocabulary")
        XCTAssertEqual(TranscriptPostProcessingMode.appleIntelligence.displayName, "Apple Intelligence")
        XCTAssertEqual(TranscriptPostProcessingMode.s1Mini.displayName, "S1-mini by Superwhisper")
        XCTAssertEqual(TranscriptPostProcessingMode.ollama.displayName, "Ollama")
        XCTAssertEqual(TranscriptPostProcessingMode.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(TranscriptPostProcessingMode.openAICompatible.displayName, "OpenAI Compatible")
    }

    func testPostProcessingModeRoundTrip() {
        for mode in TranscriptPostProcessingMode.allCases {
            XCTAssertEqual(TranscriptPostProcessingMode(rawValue: mode.rawValue), mode)
        }
    }

    func testPostProcessingModeFeatureVisibilityMatrix() {
        XCTAssertEqual(
            TranscriptPostProcessingMode.none.supportedFeatures,
            [.localFillerWordRemoval]
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.fluidAudioVocabulary.supportedFeatures,
            [.customVocabulary, .localFillerWordRemoval]
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.appleIntelligence.supportedFeatures,
            [
                .customPrompt,
                .customVocabulary,
                .dictationContext,
                .categoryWritingStyles,
                .appCategories,
                .localFillerWordRemoval,
            ]
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.s1Mini.supportedFeatures,
            [
                .dictationContext,
                .s1MiniCategoryStyling,
                .appCategories,
                .s1MiniTrainedControls,
                .localFillerWordRemoval,
            ]
        )

        let remoteModelFeatures: Set<TranscriptCleanupFeature> = [
            .customPrompt,
            .customVocabulary,
            .dictationContext,
            .categoryWritingStyles,
            .appCategories,
            .remoteContextSharing,
            .localFillerWordRemoval,
        ]
        XCTAssertEqual(TranscriptPostProcessingMode.ollama.supportedFeatures, remoteModelFeatures)
        XCTAssertEqual(TranscriptPostProcessingMode.openRouter.supportedFeatures, remoteModelFeatures)
        XCTAssertEqual(TranscriptPostProcessingMode.openAICompatible.supportedFeatures, remoteModelFeatures)

        for mode in TranscriptPostProcessingMode.allCases {
            XCTAssertEqual(
                mode.usesDictationContext,
                mode.supportedFeatures.contains(.dictationContext)
            )
            XCTAssertEqual(
                mode.canSendContextOffDevice,
                mode.supportedFeatures.contains(.remoteContextSharing)
            )
            XCTAssertTrue(mode.supportedFeatures.contains(.localFillerWordRemoval))
        }
    }

    func testPostProcessingContextSupportMatchesProviderTransport() {
        XCTAssertEqual(TranscriptPostProcessingMode.none.dictationContextSupport(), .none)
        XCTAssertEqual(TranscriptPostProcessingMode.fluidAudioVocabulary.dictationContextSupport(), .none)
        XCTAssertEqual(TranscriptPostProcessingMode.s1Mini.dictationContextSupport(), .categoryOnlyOnDevice)
        XCTAssertEqual(TranscriptPostProcessingMode.appleIntelligence.dictationContextSupport(), .fullOnDevice)
        XCTAssertEqual(
            TranscriptPostProcessingMode.ollama.dictationContextSupport(isConfiguredServerLocal: true),
            .fullLocalServer
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.openAICompatible.dictationContextSupport(isConfiguredServerLocal: false),
            .remoteCategoryWithOptionalText
        )
        XCTAssertEqual(
            TranscriptPostProcessingMode.openRouter.dictationContextSupport(isConfiguredServerLocal: true),
            .remoteCategoryWithOptionalText
        )

        XCTAssertFalse(DictationContextSupport.categoryOnlyOnDevice.includesCapturedText(remoteSharingEnabled: true))
        XCTAssertTrue(DictationContextSupport.fullOnDevice.includesCapturedText(remoteSharingEnabled: false))
        XCTAssertTrue(DictationContextSupport.fullLocalServer.includesCapturedText(remoteSharingEnabled: false))
        XCTAssertFalse(
            DictationContextSupport.remoteCategoryWithOptionalText.includesCapturedText(
                remoteSharingEnabled: false
            )
        )
        XCTAssertTrue(
            DictationContextSupport.remoteCategoryWithOptionalText.includesCapturedText(
                remoteSharingEnabled: true
            )
        )
    }

    // MARK: - AppAppearanceMode

    func testAppAppearanceModes() {
        XCTAssertEqual(AppAppearanceMode.menuBarOnly.displayName, "Menu Bar Only")
        XCTAssertEqual(AppAppearanceMode.dockAndMenuBar.displayName, "Dock and Menu Bar")
        XCTAssertEqual(AppAppearanceMode.menuBarOnly.activationPolicy, .accessory)
        XCTAssertEqual(AppAppearanceMode.dockAndMenuBar.activationPolicy, .regular)
    }

    // MARK: - SupportedLanguage

    func testSupportedLanguagesHaveUniqueIDs() {
        let ids = SupportedLanguage.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testSupportedLanguagesHaveFlags() {
        for language in SupportedLanguage.allCases {
            XCTAssertFalse(language.displayWithFlag.isEmpty)
        }
    }

    func testEnglishExists() {
        XCTAssertTrue(SupportedLanguage.allCases.contains(.english))
        XCTAssertEqual(SupportedLanguage.english.rawValue, "en")
    }

    func testChineseLanguageExists() {
        XCTAssertTrue(SupportedLanguage.allCases.contains(.chinese))
        XCTAssertEqual(SupportedLanguage.chinese.rawValue, "zh")
        XCTAssertEqual(SupportedLanguage.chinese.displayName, "Chinese (Simplified)")
        XCTAssertEqual(SupportedLanguage.chinese.nativeName, "简体中文")
    }

    func testNemotronLanguageCodes() {
        XCTAssertEqual(SupportedLanguage.chinese.nemotronLanguageCode, "zh-CN")
        XCTAssertEqual(SupportedLanguage.english.nemotronLanguageCode, "en-US")
        XCTAssertEqual(SupportedLanguage.german.nemotronLanguageCode, "de")
    }

    func testAppleSpeechLocaleForChineseIsSimplified() {
        XCTAssertEqual(AppleSpeechEngine.locale(for: .chinese).identifier, "zh-CN")
    }

    // MARK: - Sidebar pages (design conformance)

    func testSidebarPageOrderAndTitlesMatchDesign() {
        XCTAssertEqual(
            SidebarPage.allCases.map(\.title),
            ["Speech Model", "General", "Shortcuts", "Text & Overlay", "Transcript Cleanup", "History", "About"]
        )
    }

    func testSidebarPageIconsAreValidSFSymbols() {
        for page in SidebarPage.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: page.icon, accessibilityDescription: nil),
                "\(page.title) icon \(page.icon) is not a valid SF Symbol"
            )
        }
    }

    // MARK: - Window sizing

    func testWindowSizingMatchesDesignCanvas() {
        XCTAssertEqual(MainWindowSizing.defaultWidth, 1120)
        XCTAssertEqual(MainWindowSizing.defaultHeight, 780)
        XCTAssertLessThanOrEqual(MainWindowSizing.minimumWidth, MainWindowSizing.defaultWidth)
        XCTAssertLessThanOrEqual(MainWindowSizing.minimumHeight, MainWindowSizing.defaultHeight)
    }

    // MARK: - Mandarin model cases (Task 9)

    func testMandarinModelCasesExist() {
        XCTAssertEqual(ParakeetModelChoice(rawValue: "senseVoice"), .senseVoice)
        XCTAssertEqual(ParakeetModelChoice(rawValue: "nemotronMultilingual"), .nemotronMultilingual)
    }

    func testMandarinModelMetadata() {
        XCTAssertFalse(ParakeetModelChoice.senseVoice.isEnglishOnly)
        XCTAssertFalse(ParakeetModelChoice.nemotronMultilingual.isEnglishOnly)
        XCTAssertFalse(ParakeetModelChoice.senseVoice.usesTrueStreaming)
        XCTAssertTrue(ParakeetModelChoice.nemotronMultilingual.usesTrueStreaming)
        XCTAssertFalse(ParakeetModelChoice.senseVoice.supportsEndOfUtterance)
        XCTAssertFalse(ParakeetModelChoice.nemotronMultilingual.supportsEndOfUtterance)
        XCTAssertEqual(ParakeetModelChoice.senseVoice.modelDirectoryName, "sensevoice-small")
        XCTAssertEqual(ParakeetModelChoice.nemotronMultilingual.modelDirectoryName,
                       "nemotron-multilingual/multilingual/1120ms")
    }

    func testMandarinModelLanguageRules() {
        XCTAssertNil(ParakeetModelChoice.senseVoice.selectableLanguages)
        XCTAssertNotNil(ParakeetModelChoice.senseVoice.fixedLanguageLabel)
        XCTAssertEqual(ParakeetModelChoice.nemotronMultilingual.selectableLanguages,
                       SupportedLanguage.allCases)
        XCTAssertEqual(ParakeetModelChoice.multilingual.selectableLanguages,
                       SupportedLanguage.allCases.filter { $0 != .chinese })
        XCTAssertFalse(ParakeetModelChoice.multilingual.supportsLanguage(.chinese))
        XCTAssertTrue(ParakeetModelChoice.nemotronMultilingual.supportsLanguage(.chinese))
        XCTAssertTrue(ParakeetModelChoice.senseVoice.supportsLanguage(.chinese))
        XCTAssertFalse(ParakeetModelChoice.englishOnly.supportsLanguage(.chinese))
    }

    func testMandarinModelsDisableFluidAudioVocabulary() {
        XCTAssertFalse(ParakeetModelChoice.senseVoice.supportsFluidAudioVocabulary)
        XCTAssertFalse(ParakeetModelChoice.nemotronMultilingual.supportsFluidAudioVocabulary)
        XCTAssertTrue(ParakeetModelChoice.multilingual.supportsFluidAudioVocabulary)
    }
}
