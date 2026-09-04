import XCTest
@testable import Dictate_Anywhere

/// Pure resolution tests — no Settings.shared mutation, no snapshot needed.
final class InputSourceProfileResolverTests: XCTestCase {
    private func mapping(
        engine: TranscriptionEngineChoice = .parakeet,
        model: ParakeetModelChoice? = .senseVoice,
        language: SupportedLanguage = .chinese
    ) -> InputSourceMapping {
        InputSourceMapping(
            id: UUID(), inputSourceID: "src", inputSourceDisplayName: "Src",
            engine: engine, parakeetModel: model, language: language
        )
    }

    private func resolve(
        mapping: InputSourceMapping?,
        enabled: Bool = true,
        currentEngine: TranscriptionEngineChoice = .parakeet,
        currentParakeetModel: ParakeetModelChoice = .englishOnly,
        currentFluidAudioLanguage: SupportedLanguage = .english,
        currentAppleSpeechLanguage: SupportedLanguage = .english,
        appleSpeechSupported: Bool = true,
        isModelDownloaded: @escaping (ParakeetModelChoice) -> Bool = { _ in true },
        isAppleSpeechAssetInstalled: @escaping (SupportedLanguage) -> Bool = { _ in true }
    ) -> InputSourceProfileResolution {
        InputSourceProfileResolver.resolve(
            mapping: mapping,
            enabled: enabled,
            currentEngine: currentEngine,
            currentParakeetModel: currentParakeetModel,
            currentFluidAudioLanguage: currentFluidAudioLanguage,
            currentAppleSpeechLanguage: currentAppleSpeechLanguage,
            appleSpeechSupported: appleSpeechSupported,
            isModelDownloaded: isModelDownloaded,
            isAppleSpeechAssetInstalled: isAppleSpeechAssetInstalled
        )
    }

    func testDisabledOrUnmappedResolvesToNone() {
        XCTAssertEqual(resolve(mapping: mapping(), enabled: false), InputSourceProfileResolution.none)
        XCTAssertEqual(resolve(mapping: nil), InputSourceProfileResolution.none)
    }

    func testParakeetMappingWithoutModelResolvesToNone() {
        XCTAssertEqual(resolve(mapping: mapping(model: nil)), InputSourceProfileResolution.none)
    }

    func testNotDownloadedModelResolvesToInactive() {
        XCTAssertEqual(
            resolve(mapping: mapping(), isModelDownloaded: { _ in false }),
            .inactive
        )
    }

    func testAppleSpeechMappingOnUnsupportedOSResolvesToInactive() {
        XCTAssertEqual(
            resolve(mapping: mapping(engine: .appleSpeech, model: nil), appleSpeechSupported: false),
            .inactive
        )
    }

    func testExactMatchResolvesToNoChange() {
        XCTAssertEqual(
            resolve(
                mapping: mapping(),
                currentParakeetModel: .senseVoice,
                currentFluidAudioLanguage: .chinese
            ),
            .noChange
        )
        XCTAssertEqual(
            resolve(
                mapping: mapping(engine: .appleSpeech, model: nil, language: .german),
                currentEngine: .appleSpeech,
                currentAppleSpeechLanguage: .german
            ),
            .noChange
        )
    }

    func testSameModelDifferentLanguageResolvesToLanguageOnly() {
        XCTAssertEqual(
            resolve(
                mapping: mapping(model: .nemotronMultilingual, language: .chinese),
                currentParakeetModel: .nemotronMultilingual,
                currentFluidAudioLanguage: .english
            ),
            .languageOnly(.chinese)
        )
        XCTAssertEqual(
            resolve(
                mapping: mapping(engine: .appleSpeech, model: nil, language: .german),
                currentEngine: .appleSpeech,
                currentAppleSpeechLanguage: .english
            ),
            .languageOnly(.german)
        )
    }

    func testEngineOrModelMismatchResolvesToFullApply() {
        // Model mismatch on the same engine.
        XCTAssertEqual(resolve(mapping: mapping()), .fullApply)
        // Engine mismatch, both directions.
        XCTAssertEqual(
            resolve(mapping: mapping(engine: .appleSpeech, model: nil), currentEngine: .parakeet),
            .fullApply
        )
        XCTAssertEqual(resolve(mapping: mapping(), currentEngine: .appleSpeech), .fullApply)
    }

    // MARK: - Apple Speech installed-asset gate

    func testAppleSpeechMappingWithAssetNotInstalledResolvesToInactive() {
        // Would otherwise be `.noChange` (engine/language already match), but
        // auto-switching must never trigger a silent asset download.
        XCTAssertEqual(
            resolve(
                mapping: mapping(engine: .appleSpeech, model: nil, language: .german),
                currentEngine: .appleSpeech,
                currentAppleSpeechLanguage: .german,
                isAppleSpeechAssetInstalled: { _ in false }
            ),
            .inactive
        )
    }

    func testAppleSpeechMappingWithAssetInstalledPreservesPriorBehavior() {
        XCTAssertEqual(
            resolve(
                mapping: mapping(engine: .appleSpeech, model: nil),
                currentEngine: .parakeet,
                isAppleSpeechAssetInstalled: { _ in true }
            ),
            .fullApply
        )
    }
}
