//
//  TranscriptionEngine.swift
//  Dictate Anywhere
//
//  Protocol + ParakeetEngine (FluidAudio) + AppleSpeechEngine implementations.
//

import Foundation
import AVFoundation
import CoreAudio
import Accelerate
import FluidAudio
import Speech
import os

// MARK: - Protocol

protocol TranscriptionEngine: AnyObject {
    var isReady: Bool { get }
    var currentTranscript: String { get }
    var audioSamples: [Float] { get }
    /// Thread-safe snapshot of recent audio samples for level visualization.
    func levelSamples(count: Int) -> [Float]
    func prepare() async throws
    func startRecording(deviceID: AudioDeviceID?) async throws
    func stopRecording() async -> String
    func cancel() async
}

// MARK: - Shared Audio Helpers

/// Creates and configures an AVAudioEngine for recording to 16kHz mono Float32
private func makeRecordingEngine(
    deviceID: AudioDeviceID?,
    onSamples: @escaping ([Float]) -> Void
) throws -> (AVAudioEngine, AVAudioConverter) {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode

    // Set input device if specified
    if let deviceID, deviceID != 0, deviceID != AudioDeviceID(kAudioObjectUnknown) {
        guard let audioUnit = inputNode.audioUnit else {
            throw TranscriptionError.audioEngineSetupFailed
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw TranscriptionError.deviceSelectionFailed
        }
    }

    engine.reset()

    let hwFormat = inputNode.inputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
        throw TranscriptionError.audioEngineSetupFailed
    }

    guard let recFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwFormat.sampleRate, channels: 1, interleaved: false) else {
        throw TranscriptionError.audioFormatError
    }
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
        throw TranscriptionError.audioFormatError
    }
    guard let converter = AVAudioConverter(from: recFormat, to: targetFormat) else {
        throw TranscriptionError.audioFormatError
    }

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: recFormat) { buffer, _ in
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        )
        guard frameCapacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        converter.reset()
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil,
              let data = converted.floatChannelData?[0],
              converted.frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
        onSamples(samples)
    }

    engine.prepare()
    try engine.start()

    guard engine.isRunning else {
        throw TranscriptionError.audioEngineSetupFailed
    }

    return (engine, converter)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case audioEngineSetupFailed
    case audioFormatError
    case deviceSelectionFailed
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .audioEngineSetupFailed: return "Failed to set up audio capture."
        case .audioFormatError: return "Failed to create audio format."
        case .deviceSelectionFailed: return "Failed to select the specified microphone."
        case .engineNotReady: return "Transcription engine is not ready."
        }
    }
}

// MARK: - ParakeetEngine

@Observable
final class ParakeetEngine: TranscriptionEngine {
    // MARK: - State

    private(set) var isReady: Bool = false
    var currentTranscript: String = ""
    var audioSamples: [Float] = []

    // Model management
    var isModelDownloaded: Bool = false
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0

    // MARK: - Private

    private var loadedModels: AsrModels?
    private let asrCoordinator = AsrManagerCoordinator()
    private var audioEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private var totalSampleCount: Int = 0
    private var committedTranscript: String = ""
    private let sampleLock = NSLock()
    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private var isRecordingActive = false

    private let isModelDownloadedKey = "isFluidModelDownloaded"
    private let minAudioEnergy: Float = 0.005
    private let transcriptionIntervalMs: UInt64 = 500
    private let sampleRate: Int = 16_000
    private let minTranscriptionDeltaSamples: Int = 4_800
    private let audioLevelWindowSamples: Int = 1_600
    private let speechCheckWindowSamples: Int = 8_000

    /// Keeps pending Parakeet context bounded for long recordings.
    private var chunkTranscriptionSamples: Int { sampleRate * 20 }
    private var maxPendingSamplesBeforeCommit: Int { sampleRate * 30 }
    private var hardPendingSampleCap: Int { sampleRate * 120 }

    /// Serial queue for audio engine lifecycle
    private let engineQueue = DispatchQueue(label: "com.dictate-anywhere.parakeet-engine", qos: .userInitiated)
    /// Recently torn down engines kept alive briefly
    private var retiredEngines: [AVAudioEngine] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "ParakeetEngine"
    )

    // MARK: - Init

    init() {
        isModelDownloaded = UserDefaults.standard.bool(forKey: isModelDownloadedKey)
    }

    // MARK: - Model Management

    /// Cached result of on-disk model check (avoids synchronous FileManager I/O on main thread)
    private var modelOnDiskCached: Bool?

    func checkModelOnDisk() -> Bool {
        if let cached = modelOnDiskCached { return cached }
        let result = Self.checkModelOnDiskSync()
        modelOnDiskCached = result
        return result
    }

    /// Recheck model on disk from a background thread and cache the result.
    func recheckModelOnDisk() async {
        let result = await Task.detached(priority: .utility) {
            Self.checkModelOnDiskSync()
        }.value
        modelOnDiskCached = result
    }

    nonisolated private static func checkModelOnDiskSync() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        if let contents = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
            return contents.contains { $0.lastPathComponent.hasPrefix("parakeet") }
        }
        return false
    }

    func downloadModel() async throws {
        guard !isDownloading else { return }

        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
        }

        let modelsExist = checkModelOnDisk()

        // Simulate progress for fresh downloads
        let progressTask = Task { @MainActor in
            guard !modelsExist else { return }
            for i in 1...90 {
                guard self.isDownloading else { break }
                self.downloadProgress = min(0.9, Double(i) / 100.0)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            progressTask.cancel()
            self.loadedModels = models

            let config = ASRConfig(streamingEnabled: true, streamingThreshold: 160_000)
            try await asrCoordinator.initialize(models: models, config: config)

            self.modelOnDiskCached = true
            await MainActor.run {
                self.isModelDownloaded = true
                self.isDownloading = false
                self.downloadProgress = 1.0
                self.isReady = true
                UserDefaults.standard.set(true, forKey: self.isModelDownloadedKey)
            }
        } catch {
            progressTask.cancel()
            await MainActor.run {
                self.isDownloading = false
                self.downloadProgress = 0.0
            }
            throw error
        }
    }

    func deleteModel() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")

        if FileManager.default.fileExists(atPath: path.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            for item in contents where item.lastPathComponent.hasPrefix("parakeet") {
                try FileManager.default.removeItem(at: item)
            }
        }

        await asrCoordinator.cleanup()
        loadedModels = nil
        modelOnDiskCached = nil

        await MainActor.run {
            self.isModelDownloaded = false
            self.isReady = false
            UserDefaults.standard.set(false, forKey: self.isModelDownloadedKey)
        }
    }

    // MARK: - TranscriptionEngine

    func levelSamples(count: Int) -> [Float] {
        sampleLock.withLock { Array(sampleBuffer.suffix(count)) }
    }

    func prepare() async throws {
        guard loadedModels == nil else {
            isReady = true
            return
        }

        // Only prepare if model is on disk (don't auto-download)
        guard checkModelOnDisk() else { return }

        let models = try await AsrModels.downloadAndLoad(version: .v3)
        self.loadedModels = models

        let config = ASRConfig(streamingEnabled: true, streamingThreshold: 160_000)
        try await asrCoordinator.initialize(models: models, config: config)

        await MainActor.run {
            self.isReady = true
            self.isModelDownloaded = true
        }
    }

    func startRecording(deviceID: AudioDeviceID?) async throws {
        guard await asrCoordinator.isInitialized() else {
            throw TranscriptionError.engineNotReady
        }

        // Clear state
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: true)
            totalSampleCount = 0
        }
        committedTranscript = ""

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }

        // Start audio engine (async to avoid deadlock — the tap callback dispatches to main)
        let (engine, _) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(AVAudioEngine, AVAudioConverter), Error>) in
            engineQueue.async {
                do {
                    let result = try makeRecordingEngine(deviceID: deviceID) { [weak self] samples in
                        guard let self else { return }
                        var droppedCount = 0
                        self.sampleLock.withLock {
                            // Trim before appending to avoid memory spike
                            let projectedCount = self.sampleBuffer.count + samples.count
                            if projectedCount > self.hardPendingSampleCap {
                                droppedCount = projectedCount - self.hardPendingSampleCap
                                let toRemove = min(droppedCount, self.sampleBuffer.count)
                                if toRemove > 0 {
                                    self.sampleBuffer.removeFirst(toRemove)
                                }
                            }
                            self.sampleBuffer.append(contentsOf: samples)
                            self.totalSampleCount += samples.count
                        }
                        if droppedCount > 0 {
                            self.logger.warning("Dropped \(droppedCount, privacy: .public) buffered samples to avoid memory pressure.")
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        audioEngine = engine
        isRecordingActive = true

        // Start transcription loop
        isTranscribing = true
        transcriptionTask = Task { [weak self] in
            await self?.transcriptionLoop()
        }
    }

    func stopRecording() async -> String {
        guard isRecordingActive else { return currentTranscript }

        // Stop transcription loop
        isTranscribing = false
        if let task = transcriptionTask {
            task.cancel()
            _ = await task.result
            transcriptionTask = nil
        }

        // Stop audio engine
        teardownAudioEngine()

        // Final transcription
        let final_transcript = await performFinalTranscription()
        isRecordingActive = false
        committedTranscript = ""
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: false)
            totalSampleCount = 0
        }

        await MainActor.run {
            self.currentTranscript = final_transcript
            self.audioSamples = []
        }

        return final_transcript
    }

    func cancel() async {
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        teardownAudioEngine()
        isRecordingActive = false
        committedTranscript = ""
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: false)
            totalSampleCount = 0
        }

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }
    }

    // MARK: - Transcription Loop

    private func transcriptionLoop() async {
        guard await asrCoordinator.isInitialized() else { return }
        var lastObservedSampleCount = 0

        while isTranscribing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(transcriptionIntervalMs))
            guard isTranscribing else { break }

            await commitBufferedChunksIfNeeded(force: false)

            let (totalSamples, recentSamples) = sampleLock.withLock { () -> (Int, [Float]) in
                let total = totalSampleCount
                let recent = Array(sampleBuffer.suffix(speechCheckWindowSamples))
                return (total, recent)
            }

            let newSampleCount = totalSamples - lastObservedSampleCount
            guard newSampleCount > minTranscriptionDeltaSamples else {
                continue
            }

            let hasSignificant = hasSignificantAudio(recentSamples)
            if hasSignificant {
                do {
                    let pendingSamples = sampleLock.withLock { sampleBuffer }
                    let result = try await asrCoordinator.transcribe(pendingSamples)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let merged = mergeTranscripts(base: committedTranscript, addition: text)
                    if !merged.isEmpty {
                        await MainActor.run { self.currentTranscript = merged }
                    }
                } catch {
                    // Continue on error
                }
            }

            lastObservedSampleCount = totalSamples
        }
    }

    private func performFinalTranscription() async -> String {
        guard await asrCoordinator.isInitialized() else { return currentTranscript }

        // Capture the live transcript before re-transcription overwrites it.
        // The transcription loop already produced a complete result in currentTranscript.
        let liveText = currentTranscript

        await commitBufferedChunksIfNeeded(force: true)

        let samples = sampleLock.withLock { sampleBuffer }
        var finalTranscript = committedTranscript

        guard samples.count > 8000, hasSignificantAudio(samples) else {
            let result = finalTranscript.isEmpty ? liveText : finalTranscript
            return result.count >= liveText.count ? result : liveText
        }

        do {
            let result = try await asrCoordinator.transcribe(samples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            finalTranscript = mergeTranscripts(base: finalTranscript, addition: text)
        } catch {
            // Fall through to length comparison below
        }

        // Return whichever captured more text
        let result = finalTranscript.isEmpty ? liveText : finalTranscript
        return result.count >= liveText.count ? result : liveText
    }

    private func hasSignificantAudio(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var rms: Float = 0
        let recent = Array(samples.suffix(speechCheckWindowSamples))
        vDSP_rmsqv(recent, 1, &rms, vDSP_Length(recent.count))
        return rms > minAudioEnergy
    }

    private func commitBufferedChunksIfNeeded(force: Bool) async {
        while true {
            let chunk = sampleLock.withLock { () -> [Float] in
                let buffered = sampleBuffer.count
                let shouldCommit = force
                    ? buffered >= chunkTranscriptionSamples
                    : buffered >= maxPendingSamplesBeforeCommit
                guard shouldCommit else { return [] }
                return Array(sampleBuffer.prefix(chunkTranscriptionSamples))
            }

            guard !chunk.isEmpty else { break }

            do {
                let result = try await asrCoordinator.transcribe(chunk)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                sampleLock.withLock {
                    let toRemove = min(chunkTranscriptionSamples, sampleBuffer.count)
                    if toRemove > 0 {
                        sampleBuffer.removeFirst(toRemove)
                    }
                }
                if !text.isEmpty {
                    committedTranscript = mergeTranscripts(base: committedTranscript, addition: text)
                    await MainActor.run { self.currentTranscript = committedTranscript }
                }
            } catch {
                logger.error("Chunk transcription failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    private func mergeTranscripts(base: String, addition: String) -> String {
        let lhs = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = addition.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }

        if lhs.hasSuffix(rhs) { return lhs }
        if rhs.hasPrefix(lhs) { return rhs }

        let maxOverlap = min(120, min(lhs.count, rhs.count))
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 8, by: -1) {
                let leftSlice = lhs.suffix(overlap)
                let rightSlice = rhs.prefix(overlap)
                if leftSlice == rightSlice {
                    let tail = String(rhs.dropFirst(overlap)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tail.isEmpty else { return lhs }
                    let separator = lhs.hasSuffix(" ") || tail.hasPrefix(",") || tail.hasPrefix(".") ? "" : " "
                    return lhs + separator + tail
                }
            }
        }

        let separator = lhs.hasSuffix(" ") || rhs.hasPrefix(",") || rhs.hasPrefix(".") ? "" : " "
        return lhs + separator + rhs
    }

    // MARK: - Audio Engine Lifecycle

    /// Maximum number of retired engines kept alive (prevents unbounded growth from rapid start/stop)
    private let maxRetiredEngines = 3

    private func teardownAudioEngine() {
        guard let engine = audioEngine else { return }
        audioEngine = nil

        engineQueue.async { [weak self] in
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            engine.reset()

            guard let self else { return }

            // Cap retired engines to prevent memory growth from rapid start/stop
            if self.retiredEngines.count >= self.maxRetiredEngines {
                self.retiredEngines.removeFirst()
            }

            // Keep alive briefly to avoid late CoreAudio callbacks
            self.retiredEngines.append(engine)
            self.engineQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.retiredEngines.removeAll { $0 === engine }
            }
        }
    }
}

// MARK: - AsrManagerCoordinator

private actor AsrManagerCoordinator {
    private var manager: AsrManager?

    func isInitialized() -> Bool { manager != nil }

    func initialize(models: AsrModels, config: ASRConfig) async throws {
        manager?.cleanup()
        let m = AsrManager(config: config)
        try await m.initialize(models: models)
        manager = m
    }

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        guard let manager else { throw TranscriptionError.engineNotReady }
        return try await manager.transcribe(samples)
    }

    func cleanup() {
        manager?.cleanup()
        manager = nil
    }
}

// MARK: - AppleSpeechEngine

@Observable
final class AppleSpeechEngine: TranscriptionEngine {
    // MARK: - State

    var isReady: Bool = false
    var currentTranscript: String = ""
    var audioSamples: [Float] = []

    // MARK: - Private

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private let sampleLock = NSLock()
    private let rollingBufferMaxSamples: Int = 16_000 * 5

    // MARK: - TranscriptionEngine

    func levelSamples(count: Int) -> [Float] {
        sampleLock.withLock { Array(sampleBuffer.suffix(count)) }
    }

    func prepare() async throws {
        let locale = Locale(identifier: Settings.shared.selectedLanguage.rawValue)
        recognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.engineNotReady
        }

        // Request authorization
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw TranscriptionError.engineNotReady
        }

        // Check on-device support
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.engineNotReady
        }

        await MainActor.run { self.isReady = true }
    }

    func startRecording(deviceID: AudioDeviceID?) async throws {
        let locale = Locale(identifier: Settings.shared.selectedLanguage.rawValue)
        recognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.engineNotReady
        }

        // Clear state
        sampleLock.withLock { sampleBuffer.removeAll(keepingCapacity: true) }

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = Settings.shared.customVocabulary
        recognitionRequest = request

        // Start audio engine
        let (engine, _) = try makeRecordingEngine(deviceID: deviceID) { [weak self] samples in
            guard let self else { return }
            self.sampleLock.withLock {
                self.sampleBuffer.append(contentsOf: samples)
                if self.sampleBuffer.count > self.rollingBufferMaxSamples {
                    self.sampleBuffer.removeFirst(self.sampleBuffer.count - self.rollingBufferMaxSamples)
                }
            }

            // Feed samples to SFSpeechRecognizer
            // Convert back to AVAudioPCMBuffer for Speech framework
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
            request.append(buffer)
        }

        audioEngine = engine

        // Start recognition
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.currentTranscript = text
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                // Recognition ended
            }
        }
    }

    func stopRecording() async -> String {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        sampleLock.withLock { sampleBuffer.removeAll(keepingCapacity: false) }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            engine.reset()
            audioEngine = nil
        }

        // Brief delay for final results
        try? await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            self.audioSamples = []
        }

        return currentTranscript
    }

    func cancel() async {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        sampleLock.withLock { sampleBuffer.removeAll(keepingCapacity: false) }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            engine.reset()
            audioEngine = nil
        }

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }
    }
}
