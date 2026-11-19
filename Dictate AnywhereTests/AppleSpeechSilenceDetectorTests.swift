//
//  AppleSpeechSilenceDetectorTests.swift
//  Dictate AnywhereTests
//
//  Unit tests for AppleSpeechSilenceDetector and silence detection modes.
//

import FluidAudio
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

    @MainActor
    func testAppleSpeechEngineWiresEndOfUtteranceHandler() {
        let engine = AppleSpeechEngine()
        var eouInvoked = false
        engine.endOfUtteranceHandler = {
            eouInvoked = true
        }

        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: {
                engine.endOfUtteranceHandler?()
            }
        )
        engine.installSilenceDetectorForTesting(detector)

        detector.append(samples: makeSpeechSamples(count: 5_000))
        detector.append(samples: makeSilenceSamples(count: 20_000))

        XCTAssertTrue(eouInvoked, "Engine endOfUtteranceHandler must be called when detector triggers")
    }

    func testDroppedUnusedPreparedDetectorDeallocatesImmediately() async {
        weak var weakDetector: AppleSpeechSilenceDetector?
        do {
            let detector = AppleSpeechSilenceDetector(
                mode: .inbuilt,
                onEndOfUtterance: {}
            )
            weakDetector = detector
            XCTAssertNotNil(weakDetector)
        }
        XCTAssertNil(weakDetector, "Unused detector must deallocate when dropped without requiring explicit reset()")

        weak var weakSileroDetector: AppleSpeechSilenceDetector?
        do {
            let detector = AppleSpeechSilenceDetector(
                mode: .sileroVAD,
                onEndOfUtterance: {}
            )
            await detector.prepare()
            weakSileroDetector = detector
            XCTAssertNotNil(weakSileroDetector)
        }
        XCTAssertNil(weakSileroDetector, "Prepared Silero detector must deallocate when dropped without requiring explicit reset()")
    }

    func testContinuousSilenceRequiredAndQuietAudioResetsSilenceCounter() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // 1. Arm with speech (~300ms)
        detector.append(samples: makeSpeechSamples(count: 5_000, amplitude: 0.1))
        XCTAssertTrue(detector.debugHasSpeechStarted)

        // 2. Feed 562 ms of silence (9,000 samples @ 16 kHz, below 17,600 required)
        detector.append(samples: makeSilenceSamples(count: 9_000))
        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(detector.debugConsecutiveSilenceSamples, 9_000)

        // 3. Feed 1 second of audio in the dead zone between 0.004 and 0.006 RMS (amplitude 0.007 -> RMS ~0.00495)
        let quietAudio = makeSpeechSamples(count: 16_000, amplitude: 0.007)
        detector.append(samples: quietAudio)
        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(detector.debugConsecutiveSilenceSamples, 0, "Audio above silence threshold must reset consecutive silence samples")

        // 4. Feed another 550 ms of silence (8,800 samples, below 17,600 required)
        detector.append(samples: makeSilenceSamples(count: 8_800))
        XCTAssertEqual(triggerCount, 0, "Split silence pauses must not sum together to trigger premature auto-stop")

        // 5. Feed remaining silence to reach a full continuous 1.1s (17,600 samples)
        detector.append(samples: makeSilenceSamples(count: 8_800))
        XCTAssertEqual(triggerCount, 1, "Full continuous silence interval must trigger auto-stop")
    }

    func testSileroSpeechEndPendingWaitsForTranscriptToSettle() {
        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .sileroVAD,
            onEndOfUtterance: { triggerCount += 1 }
        )

        // Simulate speech start and transcript
        detector.observeTranscript("Hello world")
        XCTAssertTrue(detector.debugHasSpeechStarted)

        // Simulate speechEnd event while transcript is still actively updating every 256ms (4,096 samples)
        detector.debugSimulateSpeechEndEvent()
        XCTAssertTrue(detector.debugIsSpeechEndPending)

        // Supply audio chunks with transcript updates every 256ms (4,096 samples < 12,800 required)
        detector.append(samples: makeSilenceSamples(count: 4_096))
        detector.observeTranscript("Hello world, still speaking")
        XCTAssertEqual(triggerCount, 0, "Must not trigger while transcript is actively updating")

        detector.append(samples: makeSilenceSamples(count: 4_096))
        detector.observeTranscript("Hello world, still speaking more")
        XCTAssertEqual(triggerCount, 0, "Must not trigger while transcript is actively updating")

        // Now transcript settles: feed silence to exceed requiredTranscriptInactivitySamples (12,800 samples = 0.8s)
        detector.append(samples: makeSilenceSamples(count: 13_000))
        XCTAssertEqual(triggerCount, 1, "Detector must trigger once transcript settles after speechEnd")
    }

    @MainActor
    func testLateCallbackFromPreviousRecordingIsIgnored() async {
        let engine = AppleSpeechEngine()
        var triggerCount = 0
        engine.endOfUtteranceHandler = {
            triggerCount += 1
        }

        let recording1ID = UUID()
        let detector1 = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: {
                Task { @MainActor [weak engine] in
                    guard let engine else { return }
                    let isCurrent = engine.isCurrentRecordingIDForTesting(recording1ID)
                    guard isCurrent else { return }
                    engine.endOfUtteranceHandler?()
                }
            }
        )
        engine.installSilenceDetectorForTesting(detector1, recordingID: recording1ID)

        // Start a new recording (recording 2) which changes currentRecordingID
        let recording2ID = UUID()
        let detector2 = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: {}
        )
        engine.installSilenceDetectorForTesting(detector2, recordingID: recording2ID)

        // Now detector1 fires late callback
        detector1.append(samples: makeSpeechSamples(count: 5_000))
        detector1.append(samples: makeSilenceSamples(count: 20_000))

        // Give MainActor task time to run
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(triggerCount, 0, "Late callback from previous recording ID must be ignored")
    }

    func testDetectorTeardownConcurrentWithAudioAndTranscript() async {
        let detector = AppleSpeechSilenceDetector(
            mode: .inbuilt,
            onEndOfUtterance: {}
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 {
                    detector.append(samples: [Float](repeating: 0.1, count: 512))
                    detector.observeTranscript("Sample text")
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    detector.append(samples: [Float](repeating: 0, count: 512))
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    detector.reset()
                }
            }
        }
        XCTAssertFalse(detector.debugIsTriggered)
    }

    @MainActor
    func testRecordingACancelledDuringDetectorPreparationDoesNotOverwriteOrClearRecordingB() async throws {
        try XCTSkipUnless(AppleSpeechEngine.isSupported, "Apple Speech is unavailable")

        let settings = Settings.shared
        let originalMode = settings.appleSpeechSilenceDetectionMode
        settings.appleSpeechSilenceDetectionMode = .inbuilt
        defer { settings.appleSpeechSilenceDetectionMode = originalMode }

        var captureCallbacks: [([Float]) -> Void] = []
        let captureLock = NSLock()

        let engine = AppleSpeechEngine(
            sessionFactory: { _, _ in
                TestAppleSpeechSession()
            },
            audioCaptureFactory: { _, _, onSamples in
                captureLock.withLock {
                    captureCallbacks.append(onSamples)
                }
                return MockAudioCaptureController()
            }
        )

        var bAutoStopped = false
        engine.endOfUtteranceHandler = {
            bAutoStopped = true
        }

        let gate = AsyncGate()
        engine.silenceDetectorPreparationHook = {
            await gate.hold()
        }

        // 1. Start recording A in background task
        let taskA = Task {
            try await engine.startRecording(deviceID: nil)
        }

        // 2. Wait until startup A reaches detector preparation await
        await gate.waitUntilHeld()

        // 3. Cancel recording A while it is suspended in detector preparation
        await engine.cancel()

        // 4. Remove hook so recording B does not suspend
        engine.silenceDetectorPreparationHook = nil

        // 5. Start recording B
        let taskB = Task {
            try await engine.startRecording(deviceID: nil)
        }
        try await taskB.value

        // Verify B has installed its silence detector
        let detectorB = engine.currentSilenceDetectorForTesting
        XCTAssertNotNil(detectorB, "Recording B must have installed its silence detector")

        // 6. Resume recording A from detector preparation
        gate.release()

        // 7. A should complete with cancellation error (or failure)
        do {
            try await taskA.value
            XCTFail("Recording A must not succeed after cancellation")
        } catch is CancellationError {
            // Expected
        } catch {
            // Also acceptable if cancelled/engineNotReady
        }

        // 8. Verify B still has its detector and was NOT overwritten or cleared by A
        XCTAssertTrue(
            engine.currentSilenceDetectorForTesting === detectorB,
            "Recording B must retain its detector after A finishes and cleans up"
        )

        // 9. Verify B can auto-stop
        let bCallback = captureLock.withLock { captureCallbacks.last }
        XCTAssertNotNil(bCallback, "B must have registered an audio capture callback")

        bCallback?(makeSpeechSamples(count: 5_000, amplitude: 0.1))
        bCallback?(makeSilenceSamples(count: 20_000))

        // Wait for MainActor endOfUtteranceHandler task
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(bAutoStopped, "Recording B must still be able to auto-stop")

        await engine.cancel()
    }

    func testSileroQueuedAudioDoesNotPrematurelyTriggerUntilNewSilenceArrives() async throws {
        try XCTSkipUnless(
            BatchSpeechDetection.isDownloaded(at: BatchSpeechDetection.modelURL),
            "Silero VAD model required for neural path test"
        )

        var triggerCount = 0
        let detector = AppleSpeechSilenceDetector(
            mode: .sileroVAD,
            onEndOfUtterance: { triggerCount += 1 }
        )

        await detector.prepare()
        XCTAssertTrue(detector.debugHasVadManager, "Silero VAD manager must be loaded")

        // 1. Queue speech followed by trailing silence aligned to VadManager.chunkSize (4,096 samples = 256ms)
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/en-recovery.wav")
        let rawSpeech: [Float]
        if let reader = try? RecoveryAudioReader(url: fixtureURL),
           let samples = try? reader.nextSamples(maxSamples: 16_384) {
            rawSpeech = samples
        } else {
            rawSpeech = makeSpeechSamples(count: 16_384, amplitude: 0.2)
        }
        // 8,192 samples of speech (2 chunks of 4,096 = 512ms, > 250ms minSpeechDuration)
        let speechSamples = Array(rawSpeech.prefix(8_192))
        // 16,384 samples of silence (4 chunks of 4,096 = 1,024ms, > 850ms minSilenceDuration)
        let queuedSilence = makeSilenceSamples(count: 16_384)

        detector.append(samples: speechSamples)
        detector.append(samples: queuedSilence)

        // 2. Update transcript while that audio is still queued
        detector.observeTranscript("Hello world from queued audio")

        let queuedSampleCount = detector.debugTotalAppendedSamples
        let expectedProcessed = (queuedSampleCount / VadManager.chunkSize) * VadManager.chunkSize
        XCTAssertEqual(detector.debugLastTranscriptSamplePosition, queuedSampleCount)

        // 3. Send no more samples and wait for queued audio to be processed
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline && detector.debugTotalProcessedSamples < expectedProcessed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(
            detector.debugTotalProcessedSamples,
            expectedProcessed,
            "Worker must process all queued samples"
        )

        // Give any pending trigger a moment to potentially fire
        try? await Task.sleep(for: .milliseconds(50))

        // 4. Verify auto-stop did NOT fire from queued audio
        XCTAssertEqual(
            triggerCount, 0,
            "Auto-stop must NOT fire because no new audio arrived after the transcript update"
        )
        XCTAssertFalse(detector.debugIsTriggered)

        // 5. Positive case: send enough new silence after the transcript update (16,384 samples = 4 chunks = 1,024ms > 800ms)
        detector.append(samples: makeSilenceSamples(count: 16_384))

        // Wait for worker to process the new silence
        let triggerDeadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < triggerDeadline && triggerCount == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // 6. Verify auto-stop fired
        XCTAssertEqual(
            triggerCount, 1,
            "Auto-stop must fire once enough new silence arrives after the transcript update"
        )
        XCTAssertTrue(detector.debugIsTriggered)
    }
}

// MARK: - Test Helpers

@MainActor
private final class TestAppleSpeechSession: AppleSpeechSessionProtocol {
    private(set) var cancelCount = 0

    func start() async throws {}
    func append(samples: [Float]) {}
    func finish() async -> String { "" }
    func cancel() async { cancelCount += 1 }
    func updateContextualVocabulary(_ terms: [String]) async throws {}
}

private final class MockAudioCaptureController: @unchecked Sendable, AudioCaptureController {
    private(set) var wasStopped = false
    func stop() { wasStopped = true }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { cont in
            lock.withLock {
                self.releaseContinuation = cont
                if let held = self.heldContinuation {
                    self.heldContinuation = nil
                    held.resume()
                } else {
                    self.isHeld = true
                }
            }
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { cont in
            lock.withLock {
                if self.isHeld {
                    cont.resume()
                } else {
                    self.heldContinuation = cont
                }
            }
        }
    }

    func release() {
        lock.withLock {
            self.releaseContinuation?.resume()
            self.releaseContinuation = nil
        }
    }
}
