//
//  AudioCaptureStartup.swift
//  Dictate Anywhere
//
//  Keeps potentially blocking CoreAudio startup work off the main actor.
//

import Foundation

nonisolated private final class AudioCaptureFactoryBox: @unchecked Sendable {
    let makeController: () throws -> AudioCaptureController

    init(makeController: @escaping () throws -> AudioCaptureController) {
        self.makeController = makeController
    }
}

nonisolated private final class AudioCaptureStartupResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AudioCaptureController, Error>?

    init(continuation: CheckedContinuation<AudioCaptureController, Error>) {
        self.continuation = continuation
    }

    /// Returns false when another result (normally the timeout) already won.
    @discardableResult
    func resume(with result: Result<AudioCaptureController, Error>) -> Bool {
        let continuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

nonisolated final class AudioCaptureStartupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var cancellationHandler: (@Sendable () -> Void)?

    /// Returns false when cancellation already happened before registration.
    func register(_ handler: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            cancellationHandler = handler
            return true
        }
    }

    func cancel() {
        let handler = lock.withLock {
            guard !isCancelled else { return nil as (@Sendable () -> Void)? }
            isCancelled = true
            let pending = cancellationHandler
            cancellationHandler = nil
            return pending
        }
        handler?()
    }
}

/// Runs audio capture construction away from the main actor and bounds how long
/// the caller waits for CoreAudio. A controller that arrives after the timeout
/// is stopped immediately so it cannot become an orphaned microphone session.
nonisolated func startAudioCaptureOffMainActor(
    timeout: TimeInterval,
    queue: DispatchQueue,
    cancellation: AudioCaptureStartupCancellation,
    makeController: @escaping () throws -> AudioCaptureController
) async throws -> AudioCaptureController {
    let factory = AudioCaptureFactoryBox(makeController: makeController)

    return try await PerfTrace.measure("audio.controllerWait") {
        try await withCheckedThrowingContinuation { continuation in
            let resolution = AudioCaptureStartupResolution(continuation: continuation)

            let registered = cancellation.register {
                resolution.resume(with: .failure(CancellationError()))
            }
            guard registered else {
                resolution.resume(with: .failure(CancellationError()))
                return
            }

            queue.async {
                do {
                    let controller = try PerfTrace.measure("audio.controllerCreate") {
                        try factory.makeController()
                    }
                    if !resolution.resume(with: .success(controller)) {
                        controller.stop()
                    }
                } catch {
                    resolution.resume(with: .failure(error))
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                resolution.resume(with: .failure(TranscriptionError.audioEngineSetupTimedOut))
            }
        }
    }
}
