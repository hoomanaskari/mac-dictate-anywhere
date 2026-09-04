import XCTest
@testable import Dictate_Anywhere

/// Pure availability-reason tests — no Settings.shared mutation, no snapshot needed.
final class InputSourceMappingAvailabilityTests: XCTestCase {
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

    private func reason(
        for mapping: InputSourceMapping,
        appleSpeechSupported: Bool = true,
        installedAppleSpeechLanguages: [SupportedLanguage] = [],
        runnableModels: [ParakeetModelChoice] = ParakeetModelChoice.availableCases(hasNeuralEngine: true),
        isModelOnDisk: @escaping (ParakeetModelChoice) -> Bool = { _ in true }
    ) -> String? {
        InputSourceMappingAvailability.inactiveReason(
            for: mapping,
            appleSpeechSupported: appleSpeechSupported,
            installedAppleSpeechLanguages: installedAppleSpeechLanguages,
            runnableModels: runnableModels,
            isModelOnDisk: isModelOnDisk
        )
    }

    func testAppleSpeechUnsupportedReturnsUnavailableReason() {
        let result = reason(
            for: mapping(engine: .appleSpeech, model: nil, language: .german),
            appleSpeechSupported: false
        )
        XCTAssertEqual(result, "Apple Speech isn't available on this Mac.")
    }

    func testAppleSpeechSupportedButLanguageNotInstalledReturnsInstallPrompt() {
        let result = reason(
            for: mapping(engine: .appleSpeech, model: nil, language: .german),
            appleSpeechSupported: true,
            installedAppleSpeechLanguages: [.english]
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("isn't installed for Apple Speech"))
    }

    func testAppleSpeechInstalledReturnsNil() {
        let result = reason(
            for: mapping(engine: .appleSpeech, model: nil, language: .german),
            appleSpeechSupported: true,
            installedAppleSpeechLanguages: [.german]
        )
        XCTAssertNil(result)
    }

    func testParakeetModelNotRunnableOnThisHardwareReturnsUnavailableReason() {
        let result = reason(
            for: mapping(model: .nemotronMultilingual),
            runnableModels: ParakeetModelChoice.availableCases(hasNeuralEngine: false)
        )
        XCTAssertEqual(result, "\(ParakeetModelChoice.nemotronMultilingual.displayName) isn't available on this Mac.")
    }

    func testParakeetRunnableButNotOnDiskReturnsDownloadPrompt() {
        let result = reason(
            for: mapping(model: .senseVoice),
            isModelOnDisk: { _ in false }
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("isn't downloaded"))
    }

    func testParakeetRunnableAndOnDiskReturnsNil() {
        let result = reason(
            for: mapping(model: .senseVoice),
            isModelOnDisk: { _ in true }
        )
        XCTAssertNil(result)
    }
}
