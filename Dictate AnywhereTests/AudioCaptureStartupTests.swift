import XCTest
@testable import Dictate_Anywhere

final class AudioCaptureStartupTests: XCTestCase {
    func testAudioCaptureStartupRunsFactoryOffMainThread() async throws {
        let controller = TestAudioCaptureController()
        let threadState = LockedValue(true)

        let result = try await startAudioCaptureOffMainActor(
            timeout: 1,
            queue: DispatchQueue(label: "AudioCaptureStartupTests.success"),
            cancellation: AudioCaptureStartupCancellation()
        ) {
            threadState.set(Thread.isMainThread)
            return controller
        }

        XCTAssertTrue(result === controller)
        XCTAssertFalse(threadState.value)
        XCTAssertFalse(controller.wasStopped)
    }

    func testStalledAudioCaptureStartupTimesOutAndStopsLateController() async {
        let controllerStopped = expectation(description: "late audio controller stopped")
        let controller = TestAudioCaptureController {
            controllerStopped.fulfill()
        }
        let startedAt = ContinuousClock.now

        do {
            _ = try await startAudioCaptureOffMainActor(
                timeout: 0.05,
                queue: DispatchQueue(label: "AudioCaptureStartupTests.timeout"),
                cancellation: AudioCaptureStartupCancellation()
            ) {
                Thread.sleep(forTimeInterval: 1)
                return controller
            }
            XCTFail("Expected audio capture startup to time out")
        } catch let error as TranscriptionError {
            guard case .audioEngineSetupTimedOut = error else {
                XCTFail("Unexpected transcription error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(500))
        await fulfillment(of: [controllerStopped], timeout: 2)
        XCTAssertTrue(controller.wasStopped)
    }

    func testCancelledAudioCaptureStartupReturnsImmediatelyAndStopsLateController() async {
        let controllerStopped = expectation(description: "cancelled late audio controller stopped")
        let controller = TestAudioCaptureController {
            controllerStopped.fulfill()
        }
        let cancellation = AudioCaptureStartupCancellation()
        let startedAt = ContinuousClock.now

        let startupTask = Task {
            try await startAudioCaptureOffMainActor(
                timeout: 2,
                queue: DispatchQueue(label: "AudioCaptureStartupTests.cancelled"),
                cancellation: cancellation
            ) {
                Thread.sleep(forTimeInterval: 1)
                return controller
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        cancellation.cancel()

        do {
            _ = try await startupTask.value
            XCTFail("Expected cancelled audio capture startup to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(500))
        await fulfillment(of: [controllerStopped], timeout: 2)
        XCTAssertTrue(controller.wasStopped)
    }
}

private final class TestAudioCaptureController: @unchecked Sendable, AudioCaptureController {
    private let lock = NSLock()
    private let onStop: () -> Void
    private var stopped = false

    init(onStop: @escaping () -> Void = {}) {
        self.onStop = onStop
    }

    var wasStopped: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        let shouldNotify = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldNotify {
            onStop()
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock {
            storage = value
        }
    }
}
