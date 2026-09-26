import XCTest
@testable import Dictate_Anywhere

#if DEBUG
final class AudioCaptureTeardownTests: XCTestCase {
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

private final class TeardownDurations: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Int] = []

    var values: [Int] { lock.withLock { durations } }

    func append(_ milliseconds: Int) {
        lock.withLock { durations.append(milliseconds) }
    }
}
#endif
