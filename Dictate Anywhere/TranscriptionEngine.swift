//
//  TranscriptionEngine.swift
//  Dictate Anywhere
//
//  Protocol + ParakeetEngine (FluidAudio) implementation.
//

import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Accelerate
import FluidAudio
import os

private let audioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
    category: "AudioPipeline"
)

private protocol AudioCaptureController: AnyObject, Sendable {
    func stop()
}

private final class AVAudioEngineCaptureController: @unchecked Sendable, AudioCaptureController {
    let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }
}

private final class SendableAudioEngineRef: @unchecked Sendable {
    let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }
}

private final class AVCaptureDeviceCaptureController: NSObject, @unchecked Sendable, AudioCaptureController, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.dictate-anywhere.capture-session-samples", qos: .userInitiated)
    private let onSamples: ([Float]) -> Void
    private var hasLoggedFirstBuffer = false

    init(device: AVCaptureDevice, onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples
        super.init()

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw TranscriptionError.audioEngineSetupFailed
        }
        session.addInput(input)

        output.audioSettings = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        guard session.canAddOutput(output) else {
            throw TranscriptionError.audioEngineSetupFailed
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func start() throws {
        session.startRunning()
        guard session.isRunning else {
            throw TranscriptionError.audioEngineSetupFailed
        }
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning {
            session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        if !hasLoggedFirstBuffer {
            hasLoggedFirstBuffer = true
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                audioLogger.info(
                    "captureSession: first buffer sampleRate=\(asbd.mSampleRate, privacy: .public), channelCount=\(asbd.mChannelsPerFrame, privacy: .public), formatID=\(asbd.mFormatID, privacy: .public)"
                )
            }
        }

        var samples = [Float](repeating: 0, count: frameCount)
        let status = samples.withUnsafeMutableBytes { rawBytes -> OSStatus in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(rawBytes.count),
                    mData: rawBytes.baseAddress
                )
            )
            return CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: &bufferList
            )
        }

        guard status == noErr else {
            audioLogger.error("captureSession: CMSampleBufferCopyPCMDataIntoAudioBufferList failed, status=\(status, privacy: .public)")
            return
        }

        onSamples(samples)
    }
}

private extension ParakeetModelChoice {
    nonisolated var tdtModelVersion: AsrModelVersion? {
        switch self {
        case .multilingual:
            return .v3
        case .englishOnly:
            return .v2
        case .compactEnglish:
            return .tdtCtc110m
        case .parakeetEou320, .nemotron560, .nemotron1120, .nemotron2240:
            return nil
        }
    }

    nonisolated var streamingModelVariant: StreamingModelVariant? {
        switch self {
        case .multilingual, .englishOnly, .compactEnglish:
            return nil
        case .parakeetEou320:
            return .parakeetEou320ms
        case .nemotron560:
            return .nemotron560ms
        case .nemotron1120:
            return .nemotron1120ms
        case .nemotron2240:
            return .nemotron2240ms
        }
    }

    nonisolated var asrConfig: ASRConfig {
        ASRConfig(
            streamingEnabled: true,
            streamingThreshold: 160_000
        )
    }
}

nonisolated private func fluidAudioModelCacheRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("FluidAudio", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
}

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
) throws -> AVAudioEngine {
    audioLogger.info("makeRecordingEngine: entry, thread=\(Thread.current.description, privacy: .public), deviceID=\(deviceID.map { String($0) } ?? "nil", privacy: .public)")
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode

    // Set input device if specified
    if let deviceID, deviceID != 0, deviceID != AudioDeviceID(kAudioObjectUnknown) {
        guard let audioUnit = inputNode.audioUnit else {
            audioLogger.error("makeRecordingEngine: inputNode.audioUnit is nil")
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
            audioLogger.error("makeRecordingEngine: AudioUnitSetProperty failed, status=\(status, privacy: .public)")
            throw TranscriptionError.deviceSelectionFailed
        }
        audioLogger.info("makeRecordingEngine: device \(deviceID, privacy: .public) selected successfully")
    }

    engine.reset()

    let hwFormat = inputNode.inputFormat(forBus: 0)
    audioLogger.info("makeRecordingEngine: hwFormat sampleRate=\(hwFormat.sampleRate, privacy: .public), channelCount=\(hwFormat.channelCount, privacy: .public)")
    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
        audioLogger.error("makeRecordingEngine: hwFormat invalid (sampleRate=0 or channelCount=0) — audio HAL not connected")
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

    var tapCallbackCount = 0
    let tapStartTime = CFAbsoluteTimeGetCurrent()
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: recFormat) { buffer, _ in
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        tapCallbackCount += 1
        if tapCallbackCount == 1 {
            let elapsed = CFAbsoluteTimeGetCurrent() - tapStartTime
            audioLogger.info("makeRecordingEngine: first tap callback after \(String(format: "%.3f", elapsed), privacy: .public)s, frameLength=\(buffer.frameLength, privacy: .public)")
        }
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
    do {
        try engine.start()
    } catch {
        audioLogger.error("makeRecordingEngine: engine.start() threw: \(error.localizedDescription, privacy: .public)")
        throw error
    }
    audioLogger.info("makeRecordingEngine: engine started, isRunning=\(engine.isRunning, privacy: .public)")

    guard engine.isRunning else {
        audioLogger.error("makeRecordingEngine: engine not running after start()")
        throw TranscriptionError.audioEngineSetupFailed
    }

    return engine
}

nonisolated private func makePCMBuffer(from samples: [Float], sampleRate: Double = 16_000) throws -> AVAudioPCMBuffer {
    guard !samples.isEmpty else {
        throw TranscriptionError.audioFormatError
    }
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ),
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
          ),
          let channelData = buffer.floatChannelData else {
        throw TranscriptionError.audioFormatError
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        guard let baseAddress = source.baseAddress else { return }
        memcpy(channelData[0], baseAddress, samples.count * MemoryLayout<Float>.stride)
    }
    return buffer
}

private func deviceUID(for deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
          let result = uid?.takeUnretainedValue() else {
        return nil
    }
    return result as String
}

private func captureDevice(for deviceID: AudioDeviceID) -> AVCaptureDevice? {
    guard let uid = deviceUID(for: deviceID) else { return nil }
    return AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    ).devices.first { $0.uniqueID == uid }
}

private func makeAudioCaptureController(
    deviceID: AudioDeviceID?,
    onSamples: @escaping ([Float]) -> Void
) throws -> AudioCaptureController {
    if Settings.shared.selectedMicrophoneUID != nil,
       let deviceID,
       let captureDevice = captureDevice(for: deviceID) {
        audioLogger.info(
            "makeAudioCaptureController: using AVCaptureSession for explicit microphone \(captureDevice.uniqueID, privacy: .public)"
        )
        let controller = try AVCaptureDeviceCaptureController(device: captureDevice, onSamples: onSamples)
        try controller.start()
        return controller
    }

    return AVAudioEngineCaptureController(engine: try makeRecordingEngine(deviceID: deviceID, onSamples: onSamples))
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
    var endOfUtteranceHandler: (() -> Void)?

    // Model management
    var isModelDownloaded: Bool = false
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0

    // MARK: - Private

    private var loadedModels: AsrModels?
    private let asrCoordinator = AsrManagerCoordinator()
    private var audioCaptureController: AudioCaptureController?
    private var sampleBuffer: [Float] = []
    private var levelSampleBuffer: [Float] = []
    private var fullRecordingSamples: [Float] = []
    private var totalSampleCount: Int = 0
    private var committedTranscript: String = ""
    private let sampleLock = NSLock()
    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private var isRecordingActive = false
    private var lastTapCallbackTime: CFAbsoluteTime = 0

    private let minAudioEnergy: Float = 0.005
    private let minimumSpeechPeak: Float = 0.02
    private let minimumSpeechSampleRatio: Float = 0.015
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
        isModelDownloaded = checkModelOnDisk()
    }

    // MARK: - Model Management

    /// Cached result of on-disk model check (avoids synchronous FileManager I/O on main thread)
    private var modelOnDiskCached: [ParakeetModelChoice: Bool] = [:]

    private var selectedModelChoice: ParakeetModelChoice {
        Settings.shared.parakeetModelChoice
    }

    private func updateSelectedModelDownloadedState() async {
        let isDownloaded = checkModelOnDisk()
        await MainActor.run {
            self.isModelDownloaded = isDownloaded
        }
    }

    func checkModelOnDisk() -> Bool {
        checkModelOnDisk(for: selectedModelChoice)
    }

    func checkModelOnDisk(for modelChoice: ParakeetModelChoice) -> Bool {
        if let cached = modelOnDiskCached[modelChoice] { return cached }
        let result = Self.checkModelOnDiskSync(for: modelChoice)
        modelOnDiskCached[modelChoice] = result
        return result
    }

    /// Recheck model on disk from a background thread and cache the result.
    func recheckModelOnDisk() async {
        await recheckModelOnDisk(for: selectedModelChoice)
    }

    func recheckModelOnDisk(for modelChoice: ParakeetModelChoice) async {
        let result = await Task.detached(priority: .utility) {
            Self.checkModelOnDiskSync(for: modelChoice)
        }.value
        modelOnDiskCached[modelChoice] = result
        if modelChoice == selectedModelChoice {
            await MainActor.run {
                self.isModelDownloaded = result
            }
        }
    }

    func recheckAllModelsOnDisk() async {
        let results = await Task.detached(priority: .utility) {
            Dictionary(
                uniqueKeysWithValues: ParakeetModelChoice.allCases.map {
                    ($0, Self.checkModelOnDiskSync(for: $0))
                }
            )
        }.value
        modelOnDiskCached = results
        await updateSelectedModelDownloadedState()
    }

    func checkAnyModelOnDisk() -> Bool {
        ParakeetModelChoice.allCases.contains { checkModelOnDisk(for: $0) }
    }

    func refreshSelectedModelReadiness() async -> Bool {
        let selectedModel = selectedModelChoice
        let coordinatorReady = await asrCoordinator.isInitialized(for: selectedModel)
        let ready = !isDownloading && coordinatorReady
        await MainActor.run {
            self.isReady = ready
        }
        return ready
    }

    func handleSelectedModelChange() async {
        let selectedModel = selectedModelChoice
        let isSelectedModelLoaded = await asrCoordinator.isInitialized(for: selectedModel)
        if !isSelectedModelLoaded {
            await MainActor.run {
                self.isReady = false
            }
            await asrCoordinator.cleanup()
            loadedModels = nil
        }

        await recheckModelOnDisk(for: selectedModel)

        let coordinatorReady = await asrCoordinator.isInitialized(for: selectedModel)
        await MainActor.run {
            self.isReady = coordinatorReady
        }
    }

    nonisolated private static func checkModelOnDiskSync(for modelChoice: ParakeetModelChoice) -> Bool {
        if let modelVersion = modelChoice.tdtModelVersion {
            let modelDirectory = AsrModels.defaultCacheDirectory(for: modelVersion)
            if !FileManager.default.fileExists(atPath: modelDirectory.path) {
                return false
            }
            return AsrModels.modelsExist(at: modelDirectory, version: modelVersion)
        }

        guard let variant = modelChoice.streamingModelVariant else { return false }
        let modelDirectory = fluidAudioModelCacheRoot().appendingPathComponent(variant.repo.folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else { return false }

        let requiredModels: Set<String>
        switch modelChoice {
        case .parakeetEou320:
            requiredModels = ModelNames.ParakeetEOU.requiredModels
        case .nemotron560, .nemotron1120, .nemotron2240:
            requiredModels = ModelNames.NemotronStreaming.requiredModels
        case .multilingual, .englishOnly, .compactEnglish:
            return false
        }

        return requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    func downloadModel() async throws {
        guard !isDownloading else { return }
        let modelChoice = selectedModelChoice

        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
            isReady = false
        }

        let modelsExist = checkModelOnDisk(for: modelChoice)

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
            if modelChoice.usesTrueStreaming {
                try await asrCoordinator.initializeStreaming(modelChoice: modelChoice)
                loadedModels = nil
            } else if let modelVersion = modelChoice.tdtModelVersion {
                let models = try await AsrModels.downloadAndLoad(version: modelVersion)
                let config = modelChoice.asrConfig
                try await asrCoordinator.initialize(models: models, config: config)
                self.loadedModels = models
            } else {
                throw TranscriptionError.engineNotReady
            }
            progressTask.cancel()

            self.modelOnDiskCached[modelChoice] = true
            await MainActor.run {
                self.isModelDownloaded = true
                self.isDownloading = false
                self.downloadProgress = 1.0
                self.isReady = true
            }
        } catch {
            progressTask.cancel()
            await asrCoordinator.cleanup()
            self.loadedModels = nil
            await MainActor.run {
                self.isDownloading = false
                self.downloadProgress = 0.0
                self.isReady = false
            }
            throw error
        }
    }

    func deleteModel() async throws {
        let modelChoice = selectedModelChoice
        let path: URL
        if let modelVersion = modelChoice.tdtModelVersion {
            path = AsrModels.defaultCacheDirectory(for: modelVersion)
        } else if let variant = modelChoice.streamingModelVariant {
            path = fluidAudioModelCacheRoot().appendingPathComponent(variant.repo.folderName, isDirectory: true)
        } else {
            throw TranscriptionError.engineNotReady
        }

        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }

        if await asrCoordinator.isInitialized(for: modelChoice) {
            await asrCoordinator.cleanup()
            loadedModels = nil
        }
        modelOnDiskCached[modelChoice] = false

        await MainActor.run {
            if self.selectedModelChoice == modelChoice {
                self.isModelDownloaded = false
                self.isReady = false
            }
        }
    }

    // MARK: - TranscriptionEngine

    func levelSamples(count: Int) -> [Float] {
        sampleLock.withLock { Array(levelSampleBuffer.suffix(count)) }
    }

    func prepare() async throws {
        let modelChoice = selectedModelChoice
        logger.info("prepare: entry for \(modelChoice.displayName, privacy: .public)")
        if await asrCoordinator.isInitialized(for: modelChoice) {
            logger.info("prepare: coordinator already initialized for selected model, early return")
            await MainActor.run {
                self.isReady = true
                self.isModelDownloaded = true
            }
            return
        }

        // Only prepare if model is on disk (don't auto-download)
        guard checkModelOnDisk(for: modelChoice) else {
            await MainActor.run {
                self.isReady = false
                self.isModelDownloaded = false
            }
            return
        }

        if modelChoice.usesTrueStreaming {
            do {
                try await asrCoordinator.initializeStreaming(modelChoice: modelChoice)
            } catch {
                await asrCoordinator.cleanup()
                loadedModels = nil
                await MainActor.run { self.isReady = false }
                throw error
            }

            loadedModels = nil
            modelOnDiskCached[modelChoice] = true

            await MainActor.run {
                self.isReady = true
                self.isModelDownloaded = true
            }
            return
        }

        guard let modelVersion = modelChoice.tdtModelVersion else {
            await MainActor.run { self.isReady = false }
            throw TranscriptionError.engineNotReady
        }

        let models: AsrModels
        if let cachedModels = loadedModels, cachedModels.version == modelVersion {
            models = cachedModels
        } else {
            models = try await AsrModels.loadFromCache(version: modelVersion)
        }

        let config = modelChoice.asrConfig
        do {
            try await asrCoordinator.initialize(models: models, config: config)
        } catch {
            await asrCoordinator.cleanup()
            loadedModels = nil
            await MainActor.run { self.isReady = false }
            throw error
        }

        loadedModels = models
        modelOnDiskCached[modelChoice] = true

        await MainActor.run {
            self.isReady = true
            self.isModelDownloaded = true
        }
    }

    func startRecording(deviceID: AudioDeviceID?) async throws {
        logger.info("startRecording: entry, thread=\(Thread.current.description, privacy: .public), deviceID=\(deviceID.map { String($0) } ?? "nil", privacy: .public)")
        let modelChoice = selectedModelChoice
        if !(await asrCoordinator.isInitialized(for: modelChoice)) {
            guard !isDownloading else {
                logger.error("startRecording: selected model is still downloading")
                throw TranscriptionError.engineNotReady
            }
            logger.warning("startRecording: coordinator not initialized, preparing selected model")
            try await prepare()
        }

        guard await asrCoordinator.isInitialized(for: modelChoice) else {
            logger.error("startRecording: coordinator not initialized")
            await MainActor.run {
                self.isReady = false
            }
            throw TranscriptionError.engineNotReady
        }
        try await asrCoordinator.resetSession(for: modelChoice)

        // Ensure a previous engine is fully torn down before starting a new one.
        await teardownAudioEngineIfNeeded()

        // Clear state
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: true)
            levelSampleBuffer.removeAll(keepingCapacity: true)
            fullRecordingSamples.removeAll(keepingCapacity: true)
            totalSampleCount = 0
        }
        committedTranscript = ""

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }

        // Start audio engine (async to avoid deadlock — the tap callback dispatches to main)
        logger.info("startRecording: dispatching to engineQueue for audio engine setup")
        let captureController = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AudioCaptureController, Error>) in
            engineQueue.async {
                do {
                    let result = try makeAudioCaptureController(deviceID: deviceID) { [weak self] samples in
                        guard let self else { return }
                        self.lastTapCallbackTime = CFAbsoluteTimeGetCurrent()
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
                            self.levelSampleBuffer.append(contentsOf: samples)
                            let levelCap = self.sampleRate * 10
                            if self.levelSampleBuffer.count > levelCap {
                                self.levelSampleBuffer.removeFirst(self.levelSampleBuffer.count - levelCap)
                            }
                            self.fullRecordingSamples.append(contentsOf: samples)
                            self.totalSampleCount += samples.count
                        }
                        if droppedCount > 0 {
                            self.logger.warning("Dropped \(droppedCount, privacy: .public) buffered samples to avoid memory pressure.")
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    audioLogger.error("startRecording: makeRecordingEngine failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }

        audioCaptureController = captureController
        isRecordingActive = true
        lastTapCallbackTime = CFAbsoluteTimeGetCurrent()
        logger.info("startRecording: audio engine set up successfully, starting transcription loop")

        // Start transcription loop
        isTranscribing = true
        transcriptionTask = Task { [weak self] in
            if modelChoice.usesTrueStreaming {
                await self?.streamingTranscriptionLoop()
            } else {
                await self?.transcriptionLoop()
            }
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
        await teardownAudioEngineIfNeeded()

        // Final transcription
        let final_transcript = await performFinalTranscription()
        await resetAfterStop(finalTranscript: final_transcript)

        return final_transcript
    }

    func cancel() async {
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        await teardownAudioEngineIfNeeded()
        isRecordingActive = false
        committedTranscript = ""
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: false)
            levelSampleBuffer.removeAll(keepingCapacity: false)
            fullRecordingSamples.removeAll(keepingCapacity: false)
            totalSampleCount = 0
        }

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }
    }

    // MARK: - Transcription Loop

    private func transcriptionLoop() async {
        logger.info("transcriptionLoop: entry")
        guard await asrCoordinator.isInitialized() else {
            logger.error("transcriptionLoop: coordinator not initialized, exiting")
            return
        }
        var lastObservedSampleCount = 0
        var loopIteration = 0

        while isTranscribing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(transcriptionIntervalMs))
            guard isTranscribing else { break }

            await commitBufferedChunksIfNeeded(force: false)

            loopIteration += 1
            if loopIteration % 10 == 0 {
                let sampleCount = sampleLock.withLock { sampleBuffer.count }
                logger.info("transcriptionLoop: iteration \(loopIteration, privacy: .public), buffered samples=\(sampleCount, privacy: .public)")
                let tapAge = CFAbsoluteTimeGetCurrent() - lastTapCallbackTime
                if tapAge > 2.0 {
                    logger.warning("transcriptionLoop: no tap callbacks for \(String(format: "%.1f", tapAge), privacy: .public)s — audio pipeline may be stalled")
                }
            }

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
                    logger.info("transcriptionLoop: calling transcribe with \(pendingSamples.count, privacy: .public) samples")
                    let result = try await asrCoordinator.transcribe(pendingSamples)
                    logger.info("transcriptionLoop: transcribe returned \(result.text.count, privacy: .public) chars")
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
        logger.info("transcriptionLoop: exited, isTranscribing=\(self.isTranscribing, privacy: .public), cancelled=\(Task.isCancelled, privacy: .public)")
    }

    private func streamingTranscriptionLoop() async {
        logger.info("streamingTranscriptionLoop: entry")
        guard await asrCoordinator.isInitialized(for: selectedModelChoice) else {
            logger.error("streamingTranscriptionLoop: coordinator not initialized, exiting")
            return
        }

        while isTranscribing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            guard isTranscribing else { break }

            let pendingSamples = sampleLock.withLock { () -> [Float] in
                let samples = sampleBuffer
                sampleBuffer.removeAll(keepingCapacity: true)
                return samples
            }
            guard !pendingSamples.isEmpty else {
                if await asrCoordinator.consumeEndOfUtteranceSignal() {
                    endOfUtteranceHandler?()
                }
                continue
            }

            do {
                let buffer = try makePCMBuffer(from: pendingSamples)
                try await asrCoordinator.appendStreamingAudio(buffer)
                try await asrCoordinator.processStreamingAudio()
                let text = await asrCoordinator.currentStreamingTranscript()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    await MainActor.run { self.currentTranscript = text }
                }
                if await asrCoordinator.consumeEndOfUtteranceSignal() {
                    endOfUtteranceHandler?()
                }
            } catch {
                logger.error("Streaming transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        logger.info("streamingTranscriptionLoop: exited, isTranscribing=\(self.isTranscribing, privacy: .public), cancelled=\(Task.isCancelled, privacy: .public)")
    }

    private func performFinalTranscription() async -> String {
        guard await asrCoordinator.isInitialized() else { return currentTranscript }

        // Capture the live transcript before re-transcription overwrites it.
        // The transcription loop already produced a complete result in currentTranscript.
        let liveText = currentTranscript
        if selectedModelChoice.usesTrueStreaming {
            return await finishStreamingTranscription(liveText: liveText)
        }

        let settings = Settings.shared
        let recordedSamples = sampleLock.withLock { fullRecordingSamples }

        if settings.fluidAudioVocabularyEnabled, !settings.customVocabulary.isEmpty {
            guard recordedSamples.count > 8000, containsSignificantAudio(recordedSamples) else {
                return liveText
            }

            do {
                let result = try await asrCoordinator.transcribeWithCustomVocabulary(
                    recordedSamples,
                    terms: settings.customVocabulary
                )
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text.count >= liveText.count ? text : liveText
                }
            } catch {
                logger.error("Vocabulary final transcription failed: \(error.localizedDescription, privacy: .public)")
            }

            return liveText
        }

        await commitBufferedChunksIfNeeded(force: true)

        let samples = sampleLock.withLock { sampleBuffer }
        var finalTranscript = committedTranscript

        guard samples.count > 8000, containsSignificantAudio(samples) else {
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

    private func finishStreamingTranscription(liveText: String) async -> String {
        let pendingSamples = sampleLock.withLock { () -> [Float] in
            let samples = sampleBuffer
            sampleBuffer.removeAll(keepingCapacity: true)
            return samples
        }

        do {
            if !pendingSamples.isEmpty {
                let buffer = try makePCMBuffer(from: pendingSamples)
                try await asrCoordinator.appendStreamingAudio(buffer)
                try await asrCoordinator.processStreamingAudio()
            }

            let finalText = try await asrCoordinator.finishStreaming()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else { return live }
            guard !live.isEmpty else { return finalText }
            return finalText.count >= live.count ? finalText : live
        } catch {
            logger.error("Streaming final transcription failed: \(error.localizedDescription, privacy: .public)")
            return liveText
        }
    }

    private func resetAfterStop(finalTranscript: String) async {
        isRecordingActive = false
        isTranscribing = false
        committedTranscript = ""
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: false)
            levelSampleBuffer.removeAll(keepingCapacity: false)
            fullRecordingSamples.removeAll(keepingCapacity: false)
            totalSampleCount = 0
        }

        await MainActor.run {
            self.currentTranscript = finalTranscript
            self.audioSamples = []
        }
    }

    private func hasSignificantAudio(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let recent = Array(samples.suffix(speechCheckWindowSamples))
        return audioLooksNonEmpty(recent)
    }

    private func containsSignificantAudio(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        guard samples.count > speechCheckWindowSamples else {
            return audioLooksNonEmpty(samples)
        }

        let hopSize = max(1, speechCheckWindowSamples / 2)
        var startIndex = 0
        while startIndex < samples.count {
            let endIndex = min(startIndex + speechCheckWindowSamples, samples.count)
            if audioLooksNonEmpty(Array(samples[startIndex..<endIndex])) {
                return true
            }
            if endIndex == samples.count {
                break
            }
            startIndex += hopSize
        }

        return false
    }

    private func audioLooksNonEmpty(_ samples: [Float]) -> Bool {
        audioMetrics(for: samples).looksNonEmpty
    }

    private func audioMetrics(for samples: [Float]) -> (looksNonEmpty: Bool, voicedSamples: Int) {
        guard !samples.isEmpty else { return (false, 0) }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let voicedSamples = samples.reduce(into: 0) { count, sample in
            if abs(sample) >= minimumSpeechPeak {
                count += 1
            }
        }

        if rms > minAudioEnergy {
            return (true, voicedSamples)
        }

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak >= minimumSpeechPeak else { return (false, 0) }
        let voicedRatio = Float(voicedSamples) / Float(samples.count)
        return (voicedRatio >= minimumSpeechSampleRatio, voicedSamples)
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

    private func teardownAudioEngineIfNeeded() async {
        guard let captureController = audioCaptureController else {
            logger.info("teardownAudioEngine: no capture controller to tear down")
            return
        }
        let engineRef = (captureController as? AVAudioEngineCaptureController).map { SendableAudioEngineRef($0.engine) }
        if let engineRef {
            logger.info("teardownAudioEngine: engine.isRunning=\(engineRef.engine.isRunning, privacy: .public)")
        } else {
            logger.info("teardownAudioEngine: stopping AVCaptureSession backend")
        }
        audioCaptureController = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engineQueue.async { [weak self] in
                captureController.stop()

                guard let self else {
                    continuation.resume()
                    return
                }

                guard let engineRef else {
                    continuation.resume()
                    return
                }

                // Cap retired engines to prevent memory growth from rapid start/stop.
                if self.retiredEngines.count >= self.maxRetiredEngines {
                    self.retiredEngines.removeFirst()
                }

                // Keep alive briefly to avoid late CoreAudio callbacks, but don't block caller.
                self.retiredEngines.append(engineRef.engine)
                self.engineQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.retiredEngines.removeAll { $0 === engineRef.engine }
                }

                continuation.resume()
            }
        }

        // Small settle delay reduces HAL start races on rapid re-trigger.
        try? await Task.sleep(for: .milliseconds(120))
    }
}

// MARK: - AsrManagerCoordinator

private actor AsrManagerCoordinator {
    private var manager: AsrManager?
    private var models: AsrModels?
    private var streamingManager: (any StreamingAsrManager)?
    private var streamingModelChoice: ParakeetModelChoice?
    private var pendingEndOfUtterance = false
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AsrCoordinator"
    )

    func isInitialized() -> Bool { manager != nil || streamingManager != nil }

    func isInitialized(for modelChoice: ParakeetModelChoice) -> Bool {
        if let modelVersion = modelChoice.tdtModelVersion {
            return manager != nil && models?.version == modelVersion
        }
        return streamingManager != nil && streamingModelChoice == modelChoice
    }

    func initialize(models: AsrModels, config: ASRConfig) async throws {
        logger.info("initialize: starting (existing manager=\(self.manager != nil, privacy: .public))")
        await cleanup()
        let m = AsrManager(config: config)
        try await m.loadModels(models)
        manager = m
        self.models = models
        logger.info("initialize: completed successfully")
    }

    func initializeStreaming(modelChoice: ParakeetModelChoice) async throws {
        guard modelChoice.usesTrueStreaming else { throw TranscriptionError.engineNotReady }
        if isInitialized(for: modelChoice) {
            try await resetSession(for: modelChoice)
            return
        }

        await cleanup()
        pendingEndOfUtterance = false

        switch modelChoice {
        case .parakeetEou320:
            let streaming = StreamingEouAsrManager(chunkSize: .ms320)
            await streaming.setEouCallback { [weak self] _ in
                Task { await self?.markEndOfUtteranceDetected() }
            }
            try await streaming.loadModels(to: fluidAudioModelCacheRoot(), configuration: nil, progressHandler: nil)
            streamingManager = streaming
            streamingModelChoice = modelChoice
        case .nemotron560:
            let streaming = StreamingNemotronAsrManager(requestedChunkSize: .ms560)
            try await streaming.loadModels(to: fluidAudioModelCacheRoot(), configuration: nil, progressHandler: nil)
            streamingManager = streaming
            streamingModelChoice = modelChoice
        case .nemotron1120:
            let streaming = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
            try await streaming.loadModels(to: fluidAudioModelCacheRoot(), configuration: nil, progressHandler: nil)
            streamingManager = streaming
            streamingModelChoice = modelChoice
        case .nemotron2240:
            let streaming = StreamingNemotronAsrManager(requestedChunkSize: .ms2240)
            try await streaming.loadModels(to: fluidAudioModelCacheRoot(), configuration: nil, progressHandler: nil)
            streamingManager = streaming
            streamingModelChoice = modelChoice
        case .multilingual, .englishOnly, .compactEnglish:
            throw TranscriptionError.engineNotReady
        }

        logger.info("initializeStreaming: completed for \(modelChoice.displayName, privacy: .public)")
    }

    func resetSession(for modelChoice: ParakeetModelChoice) async throws {
        guard modelChoice.usesTrueStreaming else { return }
        guard let streamingManager, streamingModelChoice == modelChoice else {
            throw TranscriptionError.engineNotReady
        }
        pendingEndOfUtterance = false
        try await streamingManager.reset()
    }

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        guard let manager else { throw TranscriptionError.engineNotReady }
        logger.info("transcribe: calling manager.transcribe with \(samples.count, privacy: .public) samples")
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        logger.info("transcribe: returned \(result.text.count, privacy: .public) chars")
        return result
    }

    func transcribeWithCustomVocabulary(_ samples: [Float], terms: [String]) async throws -> ASRResult {
        guard manager != nil else { throw TranscriptionError.engineNotReady }
        guard let models else { throw TranscriptionError.engineNotReady }

        let rawTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawTerms.isEmpty else {
            return try await transcribe(samples)
        }

        if ctcModels == nil {
            ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        }
        guard let ctcModels else {
            return try await transcribe(samples)
        }

        if ctcTokenizer == nil {
            let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
            ctcTokenizer = try await CtcTokenizer.load(from: ctcModelDir)
        }
        guard let ctcTokenizer else {
            return try await transcribe(samples)
        }

        let vocabularyTerms = rawTerms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = ctcTokenizer.encode(term)
            guard !tokenIds.isEmpty else { return nil }
            return CustomVocabularyTerm(text: term, ctcTokenIds: tokenIds)
        }
        guard !vocabularyTerms.isEmpty else {
            return try await transcribe(samples)
        }

        let vocabulary = CustomVocabularyContext(terms: vocabularyTerms)

        logger.info(
            "transcribeWithCustomVocabulary: transcribing \(samples.count, privacy: .public) samples with FluidAudio vocabulary boosting and \(vocabularyTerms.count, privacy: .public) custom terms"
        )

        let startedAt = Date()
        let streamingManager = SlidingWindowAsrManager(
            config: SlidingWindowAsrConfig(
                chunkSeconds: 11.0,
                hypothesisChunkSeconds: 1.0,
                leftContextSeconds: 2.0,
                rightContextSeconds: 2.0,
                minContextForConfirmation: 0.0,
                confirmationThreshold: 0.0
            )
        )

        do {
            try await streamingManager.configureVocabularyBoosting(
                vocabulary: vocabulary,
                ctcModels: ctcModels
            )
            try await streamingManager.loadModels(models)
            try await streamingManager.startStreaming(source: .microphone)

            let streamChunkSize = 16_000
            var offset = 0
            while offset < samples.count {
                let end = min(offset + streamChunkSize, samples.count)
                let buffer = try makePCMBuffer(from: Array(samples[offset..<end]))
                await streamingManager.streamAudio(buffer)
                offset = end
            }

            let text = try await streamingManager.finish()
            await streamingManager.cleanup()

            let result = ASRResult(
                text: text,
                confidence: 0.0,
                duration: Double(samples.count) / 16_000.0,
                processingTime: Date().timeIntervalSince(startedAt)
            )
            logger.info(
                "transcribeWithCustomVocabulary: returned \(result.text.count, privacy: .public) chars from FluidAudio vocabulary boosting"
            )
            return result
        } catch {
            await streamingManager.cleanup()
            logger.error(
                "transcribeWithCustomVocabulary: FluidAudio vocabulary boosting failed: \(error.localizedDescription, privacy: .public)"
            )
            return try await transcribe(samples)
        }
    }

    func appendStreamingAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard let streamingManager else { throw TranscriptionError.engineNotReady }
        try await streamingManager.appendAudio(buffer)
    }

    func processStreamingAudio() async throws {
        guard let streamingManager else { throw TranscriptionError.engineNotReady }
        try await streamingManager.processBufferedAudio()
    }

    func currentStreamingTranscript() async -> String {
        guard let streamingManager else { return "" }
        return await streamingManager.getPartialTranscript()
    }

    func finishStreaming() async throws -> String {
        guard let streamingManager else { throw TranscriptionError.engineNotReady }
        pendingEndOfUtterance = false
        return try await streamingManager.finish()
    }

    private func markEndOfUtteranceDetected() {
        pendingEndOfUtterance = true
    }

    func consumeEndOfUtteranceSignal() -> Bool {
        let result = pendingEndOfUtterance
        pendingEndOfUtterance = false
        return result
    }

    func cleanup() async {
        logger.info("cleanup: releasing manager (was initialized=\(self.isInitialized(), privacy: .public))")
        if let manager {
            await manager.cleanup()
        }
        if let streamingManager {
            await streamingManager.cleanup()
        }
        manager = nil
        models = nil
        streamingManager = nil
        streamingModelChoice = nil
        pendingEndOfUtterance = false
        ctcModels = nil
        ctcTokenizer = nil
    }
}
