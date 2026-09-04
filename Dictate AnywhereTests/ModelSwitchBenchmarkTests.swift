import XCTest
@testable import Dictate_Anywhere

/// Warm-cache model switch timings. Gated behind RUN_MODEL_SWITCH_BENCHMARK=1
/// because it loads real CoreML models from the app's model cache.
final class ModelSwitchBenchmarkTests: XCTestCase {
    private var savedEngineChoice: TranscriptionEngineChoice = .parakeet
    private var savedModel: ParakeetModelChoice = .multilingual
    private var savedLanguage: SupportedLanguage = .english
    private var savedMode: TranscriptPostProcessingMode = .none

    override func setUp() {
        super.setUp()
        let settings = Settings.shared
        savedEngineChoice = settings.engineChoice
        savedModel = settings.parakeetModelChoice
        savedLanguage = settings.selectedLanguage
        savedMode = settings.transcriptPostProcessingMode
    }

    override func tearDown() {
        let settings = Settings.shared
        // Model before language, post-processing mode last (didSet coercions).
        settings.engineChoice = savedEngineChoice
        settings.parakeetModelChoice = savedModel
        settings.selectedLanguage = savedLanguage
        settings.transcriptPostProcessingMode = savedMode
        super.tearDown()
    }

    @MainActor
    func testModelSwitchTimings() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MODEL_SWITCH_BENCHMARK"] == "1",
            "Set RUN_MODEL_SWITCH_BENCHMARK=1 to run the model switch benchmark"
        )
        let engine = ParakeetEngine()
        let settings = Settings.shared
        settings.engineChoice = .parakeet

        let candidates: [ParakeetModelChoice] = [
            .englishOnly, .senseVoice, .englishOnly, .nemotronMultilingual, .senseVoice,
        ]
        let sequence = candidates.filter { engine.checkModelOnDisk(for: $0) }
        try XCTSkipUnless(
            Set(sequence).count >= 2,
            "Need at least two downloaded models among \(candidates.map(\.rawValue))"
        )

        let clock = ContinuousClock()
        for target in sequence {
            settings.parakeetModelChoice = target
            await engine.handleSelectedModelChange()
            let elapsed = try await clock.measure {
                try await engine.prepare()
            }
            print("MODEL_SWITCH_BENCHMARK \(target.rawValue): \(elapsed)")
        }
    }
}
