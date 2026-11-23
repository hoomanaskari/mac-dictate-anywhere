import XCTest
@testable import Dictate_Anywhere

#if DEBUG
final class AudioCaptureTeardownTests: XCTestCase {
    func testUnusedAndExpiredRestartGatesDoNotDelayCapture() {
        let gate = AudioCaptureRestartGate()
        let stoppedAt = ContinuousClock.now
        XCTAssertEqual(gate.remaining(at: stoppedAt), .zero)
        gate.recordStop(at: stoppedAt)
        XCTAssertEqual(gate.remaining(at: stoppedAt + .seconds(1)), .zero)
    }

    func testLaterStopExtendsRestartDeadlineAndEarlierReportsCannotShortenIt() {
        let gate = AudioCaptureRestartGate()
        let firstStop = ContinuousClock.now
        let secondStop = firstStop + .milliseconds(70)
        gate.recordStop(at: firstStop)
        gate.recordStop(at: secondStop)
        gate.recordStop(at: firstStop)
        XCTAssertEqual(gate.remaining(at: firstStop + .milliseconds(120)), .milliseconds(70))
    }

    func testAudioRestartSettleWaitsOnlyForRemainingGap() {
        let stoppedAt = ContinuousClock.now
        let gate = AudioCaptureRestartGate()
        gate.recordStop(at: stoppedAt)
        XCTAssertEqual(gate.remaining(at: stoppedAt), .milliseconds(120))
        XCTAssertEqual(
            gate.remaining(at: stoppedAt + .milliseconds(70)),
            .milliseconds(50)
        )
        XCTAssertEqual(
            gate.remaining(at: stoppedAt + .milliseconds(120)),
            .zero
        )
    }

    func testParakeetCaptureStopDoesNotWaitForNextStart() async {
        let settleDurations = TeardownDurations()
        PerfTrace.onIntervalCompleted = { name, milliseconds, _ in
            if name == "audio.settle" { settleDurations.append(milliseconds) }
        }
        defer { PerfTrace.onIntervalCompleted = nil }

        let engine = ParakeetEngine()
        let controller = DelayedStopController()
        engine.installAudioCaptureControllerForTesting(controller)
        await engine.stopAudioCapture()

        XCTAssertEqual(controller.stopCount, 1)
        XCTAssertTrue(settleDurations.values.isEmpty)
        await engine.cancel()
    }

    func testParakeetFirstCaptureStopIncludesControllerShutdown() async {
        await assertFirstStopIncludesShutdown { controller in
            let engine = ParakeetEngine()
            engine.installAudioCaptureControllerForTesting(controller)
            await engine.stopAudioCapture()
            await engine.stopAudioCapture()
            await engine.cancel()
        }
    }

    func testAppleSpeechFirstCaptureStopIncludesControllerShutdown() async {
        await assertFirstStopIncludesShutdown { controller in
            let engine = AppleSpeechEngine()
            engine.installAudioCaptureControllerForTesting(controller)
            engine.stopAudioCapture()
            _ = await engine.stopRecording()
            await engine.cancel()
        }
    }

    func testAssemblyAIFirstCaptureStopIncludesControllerShutdown() async {
        await assertFirstStopIncludesShutdown { controller in
            let engine = AssemblyAIEngine()
            engine.installAudioCaptureControllerForTesting(controller)
            engine.stopAudioCapture()
            engine.stopAudioCapture()
            await engine.cancel()
        }
    }

    func testCancellationAsFirstStopStillMeasuresControllerShutdown() async {
        await assertFirstStopIncludesShutdown { controller in
            let engine = AssemblyAIEngine()
            engine.installAudioCaptureControllerForTesting(controller)
            await engine.cancel()
            engine.stopAudioCapture()
        }
    }

    func testAssemblyAICaptureStopDoesNotFinalizeAnUploadBeforeCancel() async throws {
        let settings = Settings.shared
        let preview = settings.showTextPreview
        settings.showTextPreview = false
        defer { settings.showTextPreview = preview }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AssemblyAIEngine()
        let recovery = try RecoveryAudioCapture(id: UUID(), url: directory.appendingPathComponent("capture.caf"))
        engine.recoveryCapture = recovery
        engine.apiKey = { "test-key" }
        engine.makeTestCaptureController = { onSamples in
            onSamples(Array(repeating: 0.2, count: 1_600))
            return DelayedStopController()
        }
        let receivedAudio = expectation(description: "Live upload received audio")
        let cleanEnd = expectation(description: "Live upload was finalized")
        cleanEnd.isInverted = true
        let ended = expectation(description: "Live upload stopped")
        engine.sendLiveRequest = { _, _, _, audio in
            defer { ended.fulfill() }
            for try await _ in audio.chunks {
                receivedAudio.fulfill()
            }
            try Task.checkCancellation()
            cleanEnd.fulfill()
            throw URLError(.cancelled)
        }
        try await engine.startRecording(deviceID: nil)
        await fulfillment(of: [receivedAudio], timeout: 2)
        engine.stopAudioCapture()
        await fulfillment(of: [cleanEnd], timeout: 0.15)
        await engine.cancel()
        await fulfillment(of: [ended], timeout: 2)
        let saved = await recovery.finish()
        XCTAssertEqual(saved.sampleCount, 1_600)
    }

    private func assertFirstStopIncludesShutdown(
        _ run: (DelayedStopController) async -> Void
    ) async {
        let durations = TeardownDurations()
        PerfTrace.onIntervalCompleted = { name, milliseconds, _ in
            if name == "audio.teardown" { durations.append(milliseconds) }
        }
        defer { PerfTrace.onIntervalCompleted = nil }
        let controller = DelayedStopController()
        await run(controller)
        XCTAssertEqual(controller.stopCount, 1)
        XCTAssertEqual(durations.values.count, 1, "A second stop must not emit a no-op teardown")
        if let duration = durations.values.first {
            XCTAssertGreaterThanOrEqual(duration, 100, "The interval must include controller.stop()")
        }
    }
}

private final class DelayedStopController: @unchecked Sendable, AudioCaptureController {
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }

    func stop() {
        Thread.sleep(forTimeInterval: 0.15)
        lock.withLock { stops += 1 }
    }
}

nonisolated private final class TeardownDurations: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Int] = []

    var values: [Int] { lock.withLock { durations } }

    func append(_ milliseconds: Int) {
        lock.withLock { durations.append(milliseconds) }
    }
}
#endif
