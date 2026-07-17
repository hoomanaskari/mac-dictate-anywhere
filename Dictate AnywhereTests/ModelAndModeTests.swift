import XCTest
@testable import Dictate_Anywhere_Dev

final class ModelAndModeTests: XCTestCase {

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
    }

    // MARK: - TranscriptPostProcessingMode

    func testPostProcessingModeDisplayNames() {
        XCTAssertEqual(TranscriptPostProcessingMode.none.displayName, "None")
        XCTAssertEqual(TranscriptPostProcessingMode.fluidAudioVocabulary.displayName, "FluidAudio Vocabulary")
        XCTAssertEqual(TranscriptPostProcessingMode.appleIntelligence.displayName, "Apple Intelligence")
        XCTAssertEqual(TranscriptPostProcessingMode.ollama.displayName, "Ollama")
        XCTAssertEqual(TranscriptPostProcessingMode.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(TranscriptPostProcessingMode.openAICompatible.displayName, "OpenAI Compatible")
    }

    func testPostProcessingModeRoundTrip() {
        for mode in TranscriptPostProcessingMode.allCases {
            XCTAssertEqual(TranscriptPostProcessingMode(rawValue: mode.rawValue), mode)
        }
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
}
