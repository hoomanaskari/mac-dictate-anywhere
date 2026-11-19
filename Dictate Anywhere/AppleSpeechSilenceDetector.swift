//
//  AppleSpeechSilenceDetector.swift
//  Dictate Anywhere
//
//  Silence detection and auto-stop for Apple Speech dictation.
//

import Accelerate
import CoreML
import FluidAudio
import Foundation
import os

/// Auto-stop silence detection modes for Apple Speech.
enum AppleSpeechSilenceDetectionMode: String, CaseIterable, Codable, Sendable {
    case off = "off"
    case inbuilt = "inbuilt"
    case sileroVAD = "sileroVAD"

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .inbuilt:
            return "Inbuilt (Audio & Activity)"
        case .sileroVAD:
            return "Silero VAD"
        }
    }

    var detailDescription: String {
        switch self {
        case .off:
            return "Hands-free dictation continues until manually toggled off."
        case .inbuilt:
            return "Stops hands-free dictation after a natural pause using fast audio level and speech activity."
        case .sileroVAD:
            return "Stops hands-free dictation using neural voice activity detection to resist background noise."
        }
    }
}

/// Thread-safe detector that evaluates incoming audio and transcript activity
/// to signal when hands-free speech has concluded.
final class AppleSpeechSilenceDetector: @unchecked Sendable {
    let mode: AppleSpeechSilenceDetectionMode
    private let onEndOfUtterance: @Sendable () -> Void
    private let vadModelURL: URL

    // MARK: - Tuning Parameters

    static let sampleRate = 16_000
    /// RMS threshold to qualify audio as active voice (matches AudioVolumeGate sensitivity).
    static let speechThresholdRMS: Float = 0.006
    /// RMS threshold below which audio is classified as silence.
    static let silenceThresholdRMS: Float = 0.004
    /// Minimum speech duration required to arm auto-stop (prevents clicks or initial mic pops from firing).
    static let minSpeechSamplesToArm: Int = 4_000 // 250 ms at 16 kHz
    /// Duration of trailing silence required to trigger auto-stop in Inbuilt mode.
    static let requiredSilenceSamples: Int = 17_600 // 1.1 seconds at 16 kHz
    /// Minimum audio samples that must elapse without transcript changes before auto-stopping (800 ms at 16 kHz).
    static let requiredTranscriptInactivitySamples: Int = 12_800

    // MARK: - State

    private let lock = NSLock()
    private var isTriggered = false
    private var hasSpeechStarted = false
    private var consecutiveSilenceSamples = 0
    private var consecutiveSpeechSamples = 0
    private var lastTranscript = ""
    private var samplesSinceLastTranscriptChange = 0

    // MARK: - Silero VAD State

    private var vadManager: VadManager?
    private var vadStreamState: VadStreamState?
    private var vadPendingSamples: [Float] = []
    private var vadProcessingTask: Task<Void, Never>?
    private var vadContinuation: AsyncStream<Void>.Continuation?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppleSpeechSilenceDetector"
    )

    init(
        mode: AppleSpeechSilenceDetectionMode,
        vadModelURL: URL = BatchSpeechDetection.modelURL,
        onEndOfUtterance: @escaping @Sendable () -> Void
    ) {
        self.mode = mode
        self.vadModelURL = vadModelURL
        self.onEndOfUtterance = onEndOfUtterance
    }

    deinit {
        reset()
    }

    // MARK: - Preparation

    func prepare() async {
        guard mode == .sileroVAD else { return }
        do {
            if let vad = try await BatchSpeechDetection.loadCached(at: vadModelURL) {
                // Prewarm model by running a single silent chunk through CoreML
                _ = try? await vad.processStreamingChunk(
                    [Float](repeating: 0, count: VadManager.chunkSize), state: .initial()
                )
                lock.withLock {
                    self.vadManager = vad
                    self.vadStreamState = VadStreamState.initial()
                }
                startVadProcessingLoop(vad: vad)
            } else {
                logger.notice("Silero VAD model not found on disk; falling back to inbuilt mode.")
            }
        } catch {
            logger.warning("Failed to load Silero VAD: \(error.localizedDescription, privacy: .public); falling back to inbuilt mode.")
        }
    }

    // MARK: - Audio Ingestion

    private enum Action {
        case none
        case triggerEndOfUtterance
    }

    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard mode != .off else { return }

        let action: Action = lock.withLock {
            guard !isTriggered else { return .none }

            if mode == .sileroVAD, vadManager != nil {
                vadPendingSamples.append(contentsOf: samples)
                if vadPendingSamples.count > Self.sampleRate * 10 {
                    vadPendingSamples.removeFirst(vadPendingSamples.count - Self.sampleRate * 10)
                }
                vadContinuation?.yield()
                return .none
            } else {
                return processInbuilt(samples: samples)
            }
        }

        if case .triggerEndOfUtterance = action {
            logger.info("Silence detector triggered end of utterance")
            onEndOfUtterance()
        }
    }

    // MARK: - Transcript Observation (Approach C)

    func observeTranscript(_ text: String) {
        guard mode != .off else { return }
        lock.withLock {
            guard !isTriggered else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != lastTranscript {
                lastTranscript = trimmed
                samplesSinceLastTranscriptChange = 0
                hasSpeechStarted = true
                consecutiveSilenceSamples = 0
            }
        }
    }

    // MARK: - Inbuilt Detection (Approach A + C)

    private func processInbuilt(samples: [Float]) -> Action {
        var rms: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, !ptr.isEmpty else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(ptr.count))
        }

        samplesSinceLastTranscriptChange += samples.count

        if rms >= Self.speechThresholdRMS {
            consecutiveSpeechSamples += samples.count
            consecutiveSilenceSamples = 0
            if consecutiveSpeechSamples >= Self.minSpeechSamplesToArm {
                hasSpeechStarted = true
            }
        } else if rms < Self.silenceThresholdRMS {
            consecutiveSpeechSamples = 0
            if hasSpeechStarted {
                consecutiveSilenceSamples += samples.count
            }
        }

        if hasSpeechStarted,
           consecutiveSilenceSamples >= Self.requiredSilenceSamples,
           samplesSinceLastTranscriptChange >= Self.requiredTranscriptInactivitySamples {
            isTriggered = true
            return .triggerEndOfUtterance
        }

        return .none
    }

    // MARK: - Silero VAD Processing Loop (Approach B)

    private func startVadProcessingLoop(vad: VadManager) {
        vadProcessingTask?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        lock.withLock {
            self.vadContinuation = continuation
        }

        vadProcessingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let config = VadSegmentationConfig(
                minSpeechDuration: 0.25,
                minSilenceDuration: 0.85,
                speechPadding: 0.1
            )

            for await _ in stream {
                if Task.isCancelled { break }

                while true {
                    let chunk: [Float]? = self.lock.withLock {
                        guard self.vadPendingSamples.count >= VadManager.chunkSize else { return nil }
                        let c = Array(self.vadPendingSamples.prefix(VadManager.chunkSize))
                        self.vadPendingSamples.removeFirst(VadManager.chunkSize)
                        return c
                    }
                    guard let chunk else { break }
                    guard let currentState = self.lock.withLock({ self.vadStreamState }) else { break }

                    do {
                        let result = try await vad.processStreamingChunk(chunk, state: currentState, config: config)
                        let shouldTrigger: Bool = self.lock.withLock {
                            self.vadStreamState = result.state
                            self.samplesSinceLastTranscriptChange += chunk.count

                            if result.state.triggered || result.event?.kind == .speechStart {
                                self.hasSpeechStarted = true
                                self.consecutiveSilenceSamples = 0
                            } else if result.probability < 0.3 {
                                if self.hasSpeechStarted {
                                    self.consecutiveSilenceSamples += chunk.count
                                }
                            }

                            if self.hasSpeechStarted && !self.isTriggered {
                                if result.event?.kind == .speechEnd {
                                    self.isTriggered = true
                                    return true
                                }
                                if self.consecutiveSilenceSamples >= Self.requiredSilenceSamples,
                                   self.samplesSinceLastTranscriptChange >= Self.requiredTranscriptInactivitySamples {
                                    self.isTriggered = true
                                    return true
                                }
                            }
                            return false
                        }

                        if shouldTrigger {
                            self.logger.info("Silero VAD detected end of utterance")
                            self.onEndOfUtterance()
                            return
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled { break }
                        self.logger.error("VAD chunk processing error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle

    func reset() {
        lock.withLock {
            isTriggered = false
            hasSpeechStarted = false
            consecutiveSilenceSamples = 0
            consecutiveSpeechSamples = 0
            lastTranscript = ""
            samplesSinceLastTranscriptChange = 0
            vadPendingSamples.removeAll(keepingCapacity: true)
            if vadManager != nil {
                vadStreamState = VadStreamState.initial()
            }
        }
        vadProcessingTask?.cancel()
        vadProcessingTask = nil
        vadContinuation?.finish()
        vadContinuation = nil
    }

    #if DEBUG
    var debugHasSpeechStarted: Bool {
        lock.withLock { hasSpeechStarted }
    }

    var debugIsTriggered: Bool {
        lock.withLock { isTriggered }
    }

    var debugConsecutiveSilenceSamples: Int {
        lock.withLock { consecutiveSilenceSamples }
    }
    #endif
}
