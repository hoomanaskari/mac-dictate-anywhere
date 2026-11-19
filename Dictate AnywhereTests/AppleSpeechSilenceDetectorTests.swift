//
//  AppleSpeechSilenceDetectorTests.swift
//  Dictate AnywhereTests
//
//  Unit tests for AppleSpeechSilenceDetector and silence detection modes.
//

import XCTest
@testable import Dictate_Anywhere

final class AppleSpeechSilenceDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Synthesizes a sine wave chunk to simulate speech.
    private func makeSpeechSamples(count: Int, amplitude: Float = 0.1) -> [Float] {
        (0..<count).map { i in
            sin(Float(i) * 0.05) * amplitude
        }
    }

    /// Synthesizes silent samples (all zeros).
    private func makeSilenceSamples(count: Int) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    // MARK: - Tests

    func testSilenceDetectionModeProperties() {
        XCTAssertEqual(AppleSpeechSilenceDetectionMode.off.displayName, "Off")
        XCTAssertEqual(AppleSpeechSilenceDetectionMode.inbuilt.displayName, "Inbuilt (Audio & Activity)")
        XCTAssertEqual(AppleSpeechSilenceDetectionMode.sileroVAD.displayName, "Silero VAD")

        XCTAssertFalse(AppleSpeechSilenceDetectionMode.off.detailDescription.isEmpty)
        XCTAssertFalse(AppleSpeechSilenceDetectionMode.inbuilt.detailDescription.isEmpty)
        XCTAssertFalse(AppleSpeechSilenceDetectionMode.sileroVAD.detailDescription.isEmpty)

        XCTAssertEqual(AppleSpeechSilenceDetectionMode(rawValue: "off"), .off)
        XCTAssertEqual(AppleSpeechSilenceDetectionMode(rawValue: "inbuilt"), .inbuilt)
        XCTAssertEqual(AppleSpeechSilenceDetectionMode(rawValue: "sileroVAD"), .sileroVAD)
    }

    func testSettingsPersistenceRoundTrip() {
        let settings = Settings.shared
        let original = settings.appleSpeechSilenceDetectionMode
        defer { settings.appleSpeechSilenceDetectionMode = original }

        settings.appleSpeechSilenceDetectionMode = .inbuilt
        XCTAssertEqual(settings.appleSpeechSilenceDetectionMode, .inbuilt)

        settings.appleSpeechSilenceDetectionMode = .sileroVAD
        XCTAssertEqual(settings.appleSpeechSilenceDetectionMode, .sileroVAD)

        settings.appleSpeechSilenceDetectionMode = .off
        XCTAssertEqual(settings.appleSpeechSilenceDetectionMode, .off)
    }

    func testOffModeNeverTriggers() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .off,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // Feed speech followed by extensive silence
        detector.append(samples: makeSpeechSamples(count: 8_000))
        detector.observeTranscript("Testing one two three")
        detector.append(samples: makeSilenceSamples(count: 32_000))

        XCTAssertEqual(triggerCount, 0, "Off mode must never trigger auto-stop")
    }

    func testInbuiltInitialSilenceDoesNotTrigger() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // 2 seconds of pure silence before any speech has occurred
        detector.append(samples: makeSilenceSamples(count: 32_000))

        XCTAssertFalse(detector.debugHasSpeechStarted)
        XCTAssertEqual(triggerCount, 0, "Silence before speech starts must not trigger auto-stop")
    }

    func testInbuiltSilenceDetectionTriggersAfterSpeechAndSilence() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // 1. Feed speech (~300ms, > minSpeechSamplesToArm of 250ms)
        let speech = makeSpeechSamples(count: 4_800, amplitude: 0.1)
        detector.append(samples: speech)
        XCTAssertTrue(detector.debugHasSpeechStarted, "Speech above threshold must arm the detector")

        // 2. Feed short silence (8,000 samples = 500ms, < required 1.1s)
        detector.append(samples: makeSilenceSamples(count: 8_000))
        XCTAssertEqual(triggerCount, 0, "Short pause must not trigger auto-stop")

        // 3. Feed remaining silence to exceed requiredSilenceSamples (17,600 samples = 1.1s)
        detector.append(samples: makeSilenceSamples(count: 10_000))
        XCTAssertEqual(triggerCount, 1, "Full silence duration after speech must trigger auto-stop")
        XCTAssertTrue(detector.debugIsTriggered)
    }

    func testTranscriptActivityArmsDetectorAndPostponesSilence() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // Low volume audio that does not qualify by RMS alone
        let quietAudio = makeSpeechSamples(count: 4_000, amplitude: 0.001)
        detector.append(samples: quietAudio)
        XCTAssertFalse(detector.debugHasSpeechStarted)

        // Transcript emits recognized text -> arms speech detection
        detector.observeTranscript("Hello world")
        XCTAssertTrue(detector.debugHasSpeechStarted, "Transcript observation must arm the detector")

        // Feed some silence
        detector.append(samples: makeSilenceSamples(count: 10_000))
        XCTAssertEqual(triggerCount, 0)

        // User speaks more text before silence timeout expires
        detector.observeTranscript("Hello world, more dictation text")
        XCTAssertEqual(detector.debugConsecutiveSilenceSamples, 0, "New transcript text must reset silence samples")

        // Feed silence again (not yet enough)
        detector.append(samples: makeSilenceSamples(count: 10_000))
        XCTAssertEqual(triggerCount, 0)

        // Complete silence to reach full 1.1s (17,600 samples)
        detector.append(samples: makeSilenceSamples(count: 8_000))
        XCTAssertEqual(triggerCount, 1, "Detector must fire after full silence elapsed since last transcript")
    }

    func testOneShotTriggerGuaranteesSingleExecution() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // Arm and trigger
        detector.append(samples: makeSpeechSamples(count: 5_000))
        detector.append(samples: makeSilenceSamples(count: 20_000))
        XCTAssertEqual(triggerCount, 1)

        // More silence buffers arrive
        detector.append(samples: makeSilenceSamples(count: 20_000))
        detector.append(samples: makeSilenceSamples(count: 20_000))
        XCTAssertEqual(triggerCount, 1, "Detector must fire exactly once per session")
    }

    func testResetClearsStateCompletely() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: { triggerCount += 1 }
        )

        detector.append(samples: makeSpeechSamples(count: 5_000))
        XCTAssertTrue(detector.debugHasSpeechStarted)

        detector.reset()
        XCTAssertFalse(detector.debugHasSpeechStarted)
        XCTAssertFalse(detector.debugIsTriggered)
        XCTAssertEqual(detector.debugConsecutiveSilenceSamples, 0)
    }

    func testSileroVADFallbackWhenModelMissing() async {
        var triggerCount = 0
        let nonExistentURL = URL(fileURLWithPath: "/tmp/non-existent-vad-path/model.mlmodelc")
        let detector = AppleSpeechSilenceDetector(
            mode: .sileroVAD,
            vadModelURL: nonExistentURL,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // Prepare should complete without throwing and fallback to inbuilt
        await detector.prepare()

        detector.append(samples: makeSpeechSamples(count: 5_000))
        detector.append(samples: makeSilenceSamples(count: 20_000))
        XCTAssertEqual(triggerCount, 1, "Silero VAD mode must gracefully fallback to inbuilt detection when model is missing")
    }
}
