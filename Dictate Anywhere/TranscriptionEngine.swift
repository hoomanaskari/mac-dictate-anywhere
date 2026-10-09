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
import CoreML
import os

nonisolated private let audioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
    category: "AudioPipeline"
)

nonisolated protocol AudioCaptureController: AnyObject, Sendable {
    func stop()
}

nonisolated private final class AVAudioEngineCaptureController: @unchecked Sendable, AudioCaptureController {
    let engine: AVAudioEngine
    private let samples: CapturePCMStream
    private let stopLock = NSLock()
    private var stopped = false

    init(engine: AVAudioEngine, samples: CapturePCMStream) {
        self.engine = engine
        self.samples = samples
    }

    func stop() {
        stopLock.withLock {
            guard !stopped else { return }
            stopped = true
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            samples.finish()
            engine.reset()
        }
    }
}

/// The lock orders callback delivery and the final converter tail. A Stop
/// cannot deliver tail samples before an in-flight tap has delivered its block.
nonisolated private final class CapturePCMStream: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: PCMStreamConverter
    private let onSamples: ([Float]) -> Void

    init(from input: AVAudioFormat, to output: AVAudioFormat, onSamples: @escaping ([Float]) -> Void) throws {
        converter = try PCMStreamConverter(from: input, to: output)
        self.onSamples = onSamples
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            do { deliver(try converter.convert(buffer)) }
            catch { audioLogger.error("Microphone conversion failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func finish() {
        lock.withLock {
            do { deliver(try converter.finish()) }
            catch { audioLogger.error("Microphone conversion finish failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func deliver(_ buffers: [AVAudioPCMBuffer]) {
        for buffer in buffers {
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { continue }
            onSamples(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
        }
    }
}

private final class SendableAudioEngineRef: @unchecked Sendable {
    let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }
}

nonisolated private final class AVCaptureDeviceCaptureController: NSObject, @unchecked Sendable, AudioCaptureController, AVCaptureAudioDataOutputSampleBufferDelegate {
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
        case .multilingualUltra:
            return .ultra
        case .englishOnly:
            return .v2
        case .compactEnglish:
            return .tdtCtc110m
        case .parakeetEou320, .nemotron560, .nemotron1120, .nemotron2240,
             .senseVoice, .nemotronMultilingual:
            return nil
        }
    }

    nonisolated var streamingModelVariant: StreamingModelVariant? {
        switch self {
        case .multilingual, .multilingualUltra, .englishOnly, .compactEnglish, .senseVoice, .nemotronMultilingual:
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

}

nonisolated private func fluidAudioModelCacheRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("FluidAudio", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
}

/// Removes now-empty parent directories left behind after deleting a model
/// variant nested under the FluidAudio cache root (e.g. deleting
/// "nemotron-multilingual/multilingual/1120ms" should also remove the
/// now-empty "nemotron-multilingual/multilingual" and "nemotron-multilingual"
/// directories). Stops as soon as a directory is non-empty, missing, or is
/// the cache root itself — the cache root is never removed.
nonisolated private func removeEmptyParentDirectories(from directory: URL) {
    let fileManager = FileManager.default
    let cacheRootComponents = fluidAudioModelCacheRoot().standardizedFileURL.pathComponents
    var current = directory.standardizedFileURL

    while current.pathComponents.count > cacheRootComponents.count,
          Array(current.pathComponents.prefix(cacheRootComponents.count)) == cacheRootComponents {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path),
              contents.isEmpty else {
            break
        }
        try? fileManager.removeItem(at: current)
        current = current.deletingLastPathComponent()
    }
}

// MARK: - Protocol

protocol TranscriptionEngine: AnyObject {
    var recoveryCapture: RecoveryAudioCapture? { get set }
    var isReady: Bool { get }
    var currentTranscript: String { get }
    var audioSamples: [Float] { get }
    /// Whether late destination context must be applied before final decoding.
    var requiresContextBeforeFinalization: Bool { get }
    /// Thread-safe snapshot of recent audio samples for level visualization.
    func levelSamples(count: Int) -> [Float]
    func prepare() async throws
    func startRecording(deviceID: AudioDeviceID?) async throws
    /// Stop microphone input immediately, retaining buffered audio for finalization.
    func stopAudioCapture() async
    func stopRecording() async -> String
    func cancel() async
    func transcribeRecording(at url: URL) async throws -> String
    /// Session-scoped local recognition hints. Engines that do not support
    /// contextual vocabulary safely ignore this value.
    func setSessionContextualVocabulary(_ terms: [String])
    func updateSessionContextualVocabulary(_ terms: [String]) async
    /// Session-scoped destination context. Cloud engines may use the category
    /// and, only with explicit permission, bounded surrounding text.
    func setSessionDictationContext(_ context: DictationContext?)
    /// A terminal recognition failure from the most recent stop. AppState uses
    /// this to preserve recovery audio rather than discard it as silence.
    var lastTranscriptionError: String? { get }
}

extension TranscriptionEngine {
    var requiresContextBeforeFinalization: Bool { false }
    func setSessionContextualVocabulary(_ terms: [String]) {}
    func updateSessionContextualVocabulary(_ terms: [String]) async {
        setSessionContextualVocabulary(terms)
    }
    func setSessionDictationContext(_ context: DictationContext?) {}
    var lastTranscriptionError: String? { nil }
}

// MARK: - Shared Audio Helpers

/// Creates and configures an AVAudioEngine for recording to 16kHz mono Float32
private func makeRecordingEngine(
    deviceID: AudioDeviceID?,
    onSamples: @escaping ([Float]) -> Void
) throws -> AVAudioEngineCaptureController {
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
    let samples = try CapturePCMStream(from: recFormat, to: targetFormat, onSamples: onSamples)

    var tapCallbackCount = 0
    let tapStartTime = CFAbsoluteTimeGetCurrent()
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: recFormat) { buffer, _ in
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        tapCallbackCount += 1
        if tapCallbackCount == 1 {
            let elapsed = CFAbsoluteTimeGetCurrent() - tapStartTime
            audioLogger.info("makeRecordingEngine: first tap callback after \(String(format: "%.3f", elapsed), privacy: .public)s, frameLength=\(buffer.frameLength, privacy: .public)")
        }
        samples.append(buffer)
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

    return AVAudioEngineCaptureController(engine: engine, samples: samples)
}

nonisolated func makePCMBuffer(from samples: [Float], sampleRate: Double = 16_000) throws -> AVAudioPCMBuffer {
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

func makeAudioCaptureController(
    deviceID: AudioDeviceID?,
    usesExplicitMicrophoneSelection: Bool,
    onSamples: @escaping ([Float]) -> Void
) throws -> AudioCaptureController {
    if usesExplicitMicrophoneSelection,
       let deviceID,
       let captureDevice = captureDevice(for: deviceID) {
        audioLogger.info(
            "makeAudioCaptureController: using AVCaptureSession for explicit microphone \(captureDevice.uniqueID, privacy: .public)"
        )
        let controller = try AVCaptureDeviceCaptureController(device: captureDevice, onSamples: onSamples)
        try controller.start()
        return controller
    }

    return try makeRecordingEngine(deviceID: deviceID, onSamples: onSamples)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case audioEngineSetupFailed
    case audioEngineSetupTimedOut
    case audioFormatError
    case deviceSelectionFailed
    case engineNotReady
    case appleSpeechUnavailable
    case appleSpeechLanguageUnsupported
    case speechModelLanguageUnsupported(model: String, language: String)

    var errorDescription: String? {
        switch self {
        case .audioEngineSetupFailed: return "Failed to set up audio capture."
        case .audioEngineSetupTimedOut: return "Audio capture did not start in time. Check the selected microphone and try again."
        case .audioFormatError: return "Failed to create audio format."
        case .deviceSelectionFailed: return "Failed to select the specified microphone."
        case .engineNotReady: return "Transcription engine is not ready."
        case .appleSpeechUnavailable: return "Apple Speech requires macOS 26 or later and a supported Mac."
        case .appleSpeechLanguageUnsupported: return "The selected language is not supported by Apple Speech on this Mac."
        case .speechModelLanguageUnsupported(let model, let language):
            return "\(model) does not support \(language). Choose another speech model or expected language in Speech Model settings."
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
    private(set) var isSpeechDetectionDownloaded: Bool = false

    // MARK: - Private

    private var loadedModels: AsrModels?
    private let asrCoordinator: AsrManagerCoordinator
    private let vadModelURL: URL
    private var audioCaptureController: AudioCaptureController?
    var recoveryCapture: RecoveryAudioCapture?
    private var audioCaptureStartupCancellation: AudioCaptureStartupCancellation?
    private var sampleBuffer: [Float] = []
    private var levelSampleBuffer = AudioLevelSampleBuffer()
    private var fullRecordingSamples: [Float] = []
    private var volumeGate = AudioVolumeGate()
    private var retainsOriginalAudio = false
    private var totalSampleCount: Int = 0
    private var droppedPendingSamples: Int = 0
    private let sampleLock = NSLock()
    private var activeAudioSessionID: UUID?
    private var audioProcessingContinuation: AsyncStream<Void>.Continuation?
    private var audioSignalThreshold = AudioProcessingSignalThreshold(
        thresholdSamples: BatchTranscriptionPolicy.batchProcessingSignalSamples)
    private var transcriptionTask: Task<Void, Never>?
    private var lastBatchPreviewSampleCount = 0
    private var recordingPreviewsEnabled = true
    private var recordingModelChoice: ParakeetModelChoice?
    private var recordingScriptLanguage: Language?
    private var recordingVocabularyTerms: [String] = []
    private var vocabularyPreparationIdentity: (model: ParakeetModelChoice, terms: [String])?
    private var vocabularyPreparationTaskID: UUID?
    private var vocabularyPreparationStatus: ModelReadiness = .available
    private var modelSelectionGeneration = UUID()
    private var modelDownloadOperationID: UUID?

    var vocabularyReadiness: ModelReadiness {
        guard selectedModelChoice.supportsFluidAudioVocabulary else {
            return .unavailable("This speech model does not support vocabulary recognition.")
        }
        let terms = Self.normalizedVocabulary(activeVocabularyTerms)
        guard !terms.isEmpty else { return .needsSetup }
        guard vocabularyPreparationIdentity?.model == selectedModelChoice,
              vocabularyPreparationIdentity?.terms == terms else {
            return isReady ? .available : (isModelDownloaded ? .downloaded : .notDownloaded)
        }
        if vocabularyPreparationStatus.isReady, !isReady { return isModelDownloaded ? .downloaded : .notDownloaded }
        return vocabularyPreparationStatus
    }

    nonisolated private static func normalizedVocabulary(_ terms: [String]) -> [String] {
        Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
    private var isTranscribing = false
    private var isRecordingActive = false
    /// One-shot guard for the `stt.firstPartial` trace event. Reset at every
    /// recording start so it fires exactly once per dictation session.
    private var firstPartialEmitted = false

    private let sampleRate: Int = BatchTranscriptionPolicy.sampleRate

    /// File I/O size for native recovery; recognition is fed in one-second blocks.
    nonisolated private static let recoveryReadBlockSamples = BatchTranscriptionPolicy.sampleRate * 20
    /// Keep acoustic vocabulary rescue from replacing unrelated dictation
    /// phrases (for example, "the weather is lovely" with "cancellation").
    /// The policy also tapers short-token bonuses and disables acoustic rescue.
    static let vocabularyRescorerConfig = VocabularyRescoringPolicy.config

    /// SenseVoice's fp16/int8 encoders are correct only on the Neural Engine —
    /// FluidAudio documents them as producing NaN on CPU/GPU paths. The fp32
    /// build runs on any compute unit, so non-ANE Macs load that instead.
    /// `nonisolated`: the target defaults to `MainActor` isolation, but the
    /// on-disk check and the ASR coordinator actor both read this from outside
    /// the main actor. It derives from a compile-time constant, so there is no
    /// state to protect.
    nonisolated static var senseVoiceEncoderPrecision: SenseVoiceEncoderPrecision {
        Hardware.canUseAppleNeuralEngine ? .int8 : .fp32
    }

    /// Keeps pending Parakeet context bounded for long recordings.
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

    init(vadModelURL: URL = BatchSpeechDetection.modelURL) {
        self.vadModelURL = vadModelURL
        self.asrCoordinator = AsrManagerCoordinator(vadModelURL: vadModelURL)
        isSpeechDetectionDownloaded = BatchSpeechDetection.isDownloaded(at: vadModelURL)
        isModelDownloaded = checkModelOnDisk()
    }

    // MARK: - Model Management

    /// Cached result of on-disk model check (avoids synchronous FileManager I/O on main thread)
    private var modelOnDiskCached: [ParakeetModelChoice: Bool] = [:]

    private var selectedModelChoice: ParakeetModelChoice {
        Settings.shared.parakeetModelChoice
    }

    private func ownsSelection(_ modelChoice: ParakeetModelChoice, generation: UUID) -> Bool {
        modelSelectionGeneration == generation && selectedModelChoice == modelChoice
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
        isSpeechDetectionDownloaded = BatchSpeechDetection.isDownloaded(at: vadModelURL)
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
        isSpeechDetectionDownloaded = BatchSpeechDetection.isDownloaded(at: vadModelURL)
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
        let generation = modelSelectionGeneration
        let coordinatorReady = await asrCoordinator.isInitialized(for: selectedModel)
        guard ownsSelection(selectedModel, generation: generation) else { return false }
        let ready = !isDownloading && coordinatorReady
        return await MainActor.run {
            guard self.ownsSelection(selectedModel, generation: generation) else { return false }
            self.isReady = ready
            return ready
        }
    }

    func handleSelectedModelChange() async {
        modelSelectionGeneration = UUID()
        let generation = modelSelectionGeneration
        let selectedModel = selectedModelChoice
        isReady = false
        let isSelectedModelLoaded = await asrCoordinator.isInitialized(for: selectedModel)
        guard generation == modelSelectionGeneration else { return }
        if !isSelectedModelLoaded {
            await asrCoordinator.cleanup()
            guard generation == modelSelectionGeneration else { return }
            loadedModels = nil
            invalidateVocabularyReadiness()
            await MainActor.run {
                self.isReady = false
            }
        }

        await recheckModelOnDisk(for: selectedModel)
        guard generation == modelSelectionGeneration else { return }

        let coordinatorReady = await asrCoordinator.isInitialized(for: selectedModel)
        guard generation == modelSelectionGeneration else { return }
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

        if modelChoice == .senseVoice {
            let dir = fluidAudioModelCacheRoot()
                .appendingPathComponent(modelChoice.modelDirectoryName, isDirectory: true)
            return SenseVoiceModels.modelsExist(at: dir, precision: Self.senseVoiceEncoderPrecision)
        }

        if modelChoice == .nemotronMultilingual {
            return nemotronMultilingualVariantIsComplete(
                at: fluidAudioModelCacheRoot()
                    .appendingPathComponent(modelChoice.modelDirectoryName, isDirectory: true))
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
        case .multilingual, .multilingualUltra, .englishOnly, .compactEnglish:
            return false
        case .senseVoice, .nemotronMultilingual:
            // Handled above; unreachable here.
            return false
        }

        return requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    /// True when `directory` holds every artifact
    /// `StreamingNemotronMultilingualAsrManager.loadModels(from:)` needs.
    ///
    /// `metadata.json` alone used to stand in for the whole variant, but it is
    /// a 3 KB file that lands long before the ~600 MB encoder, so a download
    /// interrupted part-way reported the model as installed and then failed at
    /// load time. This checks the artifacts the loader actually opens, in the
    /// same order of preference: compiled `.mlmodelc` first, uncompiled
    /// `.mlpackage` second (the loader compiles and caches those in place).
    ///
    /// The decode stage is satisfied by either the separate decoder + joint
    /// pair or any of the fused bundles, because the loader treats the pair as
    /// optional once a fusion is present. `preprocessor` is deliberately *not*
    /// required: FluidAudio replaced the CoreML preprocessor with a native
    /// Swift log-mel front-end (their issue #739) and never opens it, so
    /// demanding it would report a perfectly loadable variant as missing.
    nonisolated private static func nemotronMultilingualVariantIsComplete(at directory: URL) -> Bool {
        typealias Names = ModelNames.NemotronMultilingualStreaming
        let fileManager = FileManager.default

        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        /// A CoreML bundle counts as present in either compiled or raw form.
        func hasBundle(_ baseName: String) -> Bool {
            exists("\(baseName).mlmodelc") || exists("\(baseName).mlpackage")
        }

        guard exists(Names.metadata), exists(Names.tokenizer) else { return false }
        guard hasBundle(Names.encoder) else { return false }

        let hasSeparateDecodeStage = hasBundle(Names.decoder) && hasBundle(Names.joint)
        let hasFusedDecodeStage = ["decoder_joint", "decoder_joint_noencproj", "decoder_joint_argmax"]
            .contains(where: hasBundle)
        return hasSeparateDecodeStage || hasFusedDecodeStage
    }

    func downloadModel() async throws {
        let trace = PerfTrace.begin("stt.modelDownload")
        defer { trace.end() }
        guard !isDownloading, modelDownloadOperationID == nil else { return }
        let modelChoice = selectedModelChoice
        let generation = modelSelectionGeneration
        let operationID = UUID()
        modelDownloadOperationID = operationID

        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
            isReady = false
        }

        let modelsExist = checkModelOnDisk(for: modelChoice)
            && (modelChoice.usesTrueStreaming || isSpeechDetectionDownloaded)

        // Simulate progress for fresh downloads
        let progressTask = Task { @MainActor in
            guard !modelsExist else { return }
            for i in 1...90 {
                guard self.isDownloading, self.modelDownloadOperationID == operationID,
                      self.ownsSelection(modelChoice, generation: generation) else { break }
                self.downloadProgress = min(0.9, Double(i) / 100.0)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        do {
            if modelChoice == .senseVoice {
                try await asrCoordinator.initializeSenseVoice(download: true)
                loadedModels = nil
            } else if modelChoice.usesTrueStreaming {
                try await asrCoordinator.initializeStreaming(modelChoice: modelChoice)
                loadedModels = nil
            } else if let modelVersion = modelChoice.tdtModelVersion {
                let models = modelVersion == .tdtCtc110m
                    ? try await CompactSpeechModelLoader.load(download: true)
                    : try await AsrModels.downloadAndLoad(version: modelVersion)
                guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
                let config = BatchTranscriptionPolicy.asrConfig
                try await asrCoordinator.initialize(models: models, config: config, downloadSpeechDetection: true)
                guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
                self.loadedModels = models
            } else {
                throw TranscriptionError.engineNotReady
            }
            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
            progressTask.cancel()

            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
            _ = await prepareVocabularyIfNeeded(for: modelChoice, generation: generation)
            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }

            self.modelOnDiskCached[modelChoice] = true
            isSpeechDetectionDownloaded = BatchSpeechDetection.isDownloaded(at: vadModelURL)
            await MainActor.run {
                guard self.modelDownloadOperationID == operationID else { return }
                self.modelDownloadOperationID = nil
                self.isDownloading = false
                if self.selectedModelChoice == modelChoice {
                    self.isModelDownloaded = true
                    self.downloadProgress = 1.0
                } else {
                    self.downloadProgress = 0.0
                }
                if self.ownsSelection(modelChoice, generation: generation) {
                    self.isReady = true
                }
            }
        } catch {
            progressTask.cancel()
            // ASR may have completed before an optional asset failed. Keep its
            // installation visible so cache-only preparation remains available.
            await recheckModelOnDisk(for: modelChoice)
            if ownsSelection(modelChoice, generation: generation) {
                invalidateVocabularyReadiness()
                await asrCoordinator.cleanup()
                if ownsSelection(modelChoice, generation: generation) {
                    self.loadedModels = nil
                }
            }
            await MainActor.run {
                guard self.modelDownloadOperationID == operationID else { return }
                self.modelDownloadOperationID = nil
                self.isDownloading = false
                self.downloadProgress = 0.0
                if self.ownsSelection(modelChoice, generation: generation) {
                    self.isReady = false
                }
            }
            throw error
        }
    }

    /// Existing installations can opt into pause/quiet-speech detection without
    /// redownloading ASR or losing readiness if the optional download fails.
    func downloadSpeechDetection() async throws {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            isSpeechDetectionDownloaded = BatchSpeechDetection.isDownloaded(at: vadModelURL)
        }
        try await asrCoordinator.downloadSpeechDetection()
        downloadProgress = 1
    }

    func deleteModel() async throws {
        let modelChoice = selectedModelChoice
        let path: URL
        if let modelVersion = modelChoice.tdtModelVersion {
            path = AsrModels.defaultCacheDirectory(for: modelVersion)
        } else if let variant = modelChoice.streamingModelVariant {
            path = fluidAudioModelCacheRoot().appendingPathComponent(variant.repo.folderName, isDirectory: true)
        } else {
            path = fluidAudioModelCacheRoot().appendingPathComponent(modelChoice.modelDirectoryName, isDirectory: true)
        }

        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            removeEmptyParentDirectories(from: path.deletingLastPathComponent())
        }

        if await asrCoordinator.isInitialized(for: modelChoice) {
            invalidateVocabularyReadiness()
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
        sampleLock.withLock { levelSampleBuffer.latest(count: count) }
    }

    func prepare() async throws {
        isSpeechDetectionDownloaded = BatchSpeechDetection.isDownloaded(at: vadModelURL)
        let trace = PerfTrace.begin("stt.enginePrepare")
        defer { trace.end() }
        let modelChoice = selectedModelChoice
        let generation = modelSelectionGeneration
        logger.info("prepare: entry for \(modelChoice.displayName, privacy: .public)")
        if await asrCoordinator.isInitialized(for: modelChoice) {
            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
            logger.info("prepare: coordinator already initialized for selected model, early return")
            _ = await prepareVocabularyIfNeeded(for: modelChoice, generation: generation)
            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
            await MainActor.run {
                guard self.ownsSelection(modelChoice, generation: generation) else { return }
                self.isReady = true
                self.isModelDownloaded = true
            }
            return
        }

        // Only prepare if model is on disk (don't auto-download)
        guard checkModelOnDisk(for: modelChoice) else {
            await MainActor.run {
                guard self.ownsSelection(modelChoice, generation: generation) else { return }
                self.isReady = false
                self.isModelDownloaded = false
            }
            return
        }

        if modelChoice == .senseVoice {
            do {
                try await asrCoordinator.initializeSenseVoice()
            } catch {
                if ownsSelection(modelChoice, generation: generation) {
                    invalidateVocabularyReadiness()
                    await asrCoordinator.cleanup()
                    guard ownsSelection(modelChoice, generation: generation) else { throw error }
                    loadedModels = nil
                    await MainActor.run {
                        guard self.ownsSelection(modelChoice, generation: generation) else { return }
                        self.isReady = false
                    }
                }
                throw error
            }
            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
            loadedModels = nil
            modelOnDiskCached[modelChoice] = true
            await MainActor.run {
                guard self.ownsSelection(modelChoice, generation: generation) else { return }
                self.isReady = true
                self.isModelDownloaded = true
            }
            return
        }

        if modelChoice.usesTrueStreaming {
            do {
                try await asrCoordinator.initializeStreaming(modelChoice: modelChoice)
            } catch {
                if ownsSelection(modelChoice, generation: generation) {
                    invalidateVocabularyReadiness()
                    await asrCoordinator.cleanup()
                    guard ownsSelection(modelChoice, generation: generation) else { throw error }
                    loadedModels = nil
                    await MainActor.run {
                        guard self.ownsSelection(modelChoice, generation: generation) else { return }
                        self.isReady = false
                    }
                }
                throw error
            }

            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
            loadedModels = nil
            modelOnDiskCached[modelChoice] = true
            _ = await prepareVocabularyIfNeeded(for: modelChoice, generation: generation)
            guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }

            await MainActor.run {
                guard self.ownsSelection(modelChoice, generation: generation) else { return }
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
            models = modelVersion == .tdtCtc110m
                ? try await CompactSpeechModelLoader.load(download: false)
                : try await AsrModels.loadFromCache(version: modelVersion)
        }

        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }

        let config = BatchTranscriptionPolicy.asrConfig
        do {
            try await asrCoordinator.initialize(models: models, config: config)
        } catch {
            if ownsSelection(modelChoice, generation: generation) {
                invalidateVocabularyReadiness()
                await asrCoordinator.cleanup()
                guard ownsSelection(modelChoice, generation: generation) else { throw error }
                loadedModels = nil
                await MainActor.run {
                    guard self.ownsSelection(modelChoice, generation: generation) else { return }
                    self.isReady = false
                }
            }
            throw error
        }

        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        loadedModels = models
        modelOnDiskCached[modelChoice] = true

        _ = await prepareVocabularyIfNeeded(for: modelChoice, generation: generation)
        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        await MainActor.run {
            guard self.ownsSelection(modelChoice, generation: generation) else { return }
            self.isReady = true
            self.isModelDownloaded = true
        }
    }

    private func scriptLanguage(for model: ParakeetModelChoice) -> Language? {
        return BatchTranscriptionPolicy.scriptLanguage(for: model, selected: Settings.shared.selectedLanguage)
    }

    /// Vocabulary models must be resident before Stop, including when cleanup
    /// is enabled after the speech model has already been prepared.
    @discardableResult
    func prepareVocabularyIfNeeded() async -> Bool {
        let model = selectedModelChoice
        return await prepareVocabularyIfNeeded(for: model, generation: modelSelectionGeneration)
    }

    private func prepareVocabularyIfNeeded(for model: ParakeetModelChoice, generation: UUID) async -> Bool {
        guard ownsSelection(model, generation: generation), model.supportsFluidAudioVocabulary,
              await asrCoordinator.isInitialized(for: model) else { return false }
        guard ownsSelection(model, generation: generation) else { return false }
        do {
            try await prepareVocabulary(terms: activeVocabularyTerms, model: model, generation: generation)
            return ownsSelection(model, generation: generation)
        } catch {
            guard ownsSelection(model, generation: generation) else { return false }
            logger.error("Vocabulary preparation failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func prepareVocabulary(terms: [String], model: ParakeetModelChoice, generation: UUID) async throws {
        guard ownsSelection(model, generation: generation) else { throw CancellationError() }
        let id = UUID()
        vocabularyPreparationTaskID = id
        vocabularyPreparationIdentity = (model, Self.normalizedVocabulary(terms))
        vocabularyPreparationStatus = .preparing
        defer {
            if vocabularyPreparationTaskID == id {
                vocabularyPreparationTaskID = nil
                if !ownsSelection(model, generation: generation) {
                    vocabularyPreparationIdentity = nil
                    vocabularyPreparationStatus = .available
                }
            }
        }
        do {
            if model == .nemotronMultilingual {
                try await asrCoordinator.prepareStreamingVocabulary(terms: terms)
            } else {
                let progress: ProgressHandler = { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.vocabularyPreparationTaskID == id,
                              self.ownsSelection(model, generation: generation) else { return }
                        switch value.phase {
                        case .compiling: self.vocabularyPreparationStatus = .preparing
                        case .listing, .downloading: self.vocabularyPreparationStatus = .downloading(value.fractionCompleted)
                        }
                    }
                }
                try await asrCoordinator.prepareVocabulary(terms: terms, progressHandler: progress)
            }
            guard ownsSelection(model, generation: generation) else { throw CancellationError() }
            if vocabularyPreparationTaskID == id {
                vocabularyPreparationStatus = terms.isEmpty ? .available : .ready
            }
        } catch {
            if ownsSelection(model, generation: generation), vocabularyPreparationTaskID == id {
                vocabularyPreparationStatus = .failed("Vocabulary recognition could not be prepared. Check your connection and try again.")
            }
            throw error
        }
    }

    private func invalidateVocabularyReadiness() {
        vocabularyPreparationTaskID = nil
        vocabularyPreparationIdentity = nil
        vocabularyPreparationStatus = .available
    }

    private var activeVocabularyTerms: [String] {
        Settings.shared.fluidAudioVocabularyEnabled ? Settings.shared.customVocabulary : []
    }

    func startRecording(deviceID: AudioDeviceID?) async throws {
        // Validate before model loading or microphone startup. A saved language
        // can remain visible even when its old model choice was mislabeled.
        let expectedLanguage = Settings.shared.selectedLanguage
        guard selectedModelChoice.supportsLanguage(expectedLanguage) else {
            throw TranscriptionError.speechModelLanguageUnsupported(
                model: selectedModelChoice.displayName, language: expectedLanguage.displayName)
        }
        let trace = PerfTrace.begin("audio.startup")
        defer { trace.end() }
        firstPartialEmitted = false
        let startupCancellation = AudioCaptureStartupCancellation()
        audioCaptureStartupCancellation?.cancel()
        audioCaptureStartupCancellation = startupCancellation
        let recoveryCapture = self.recoveryCapture
        logger.info("startRecording: entry, thread=\(Thread.current.description, privacy: .public), deviceID=\(deviceID.map { String($0) } ?? "nil", privacy: .public)")
        let modelChoice = selectedModelChoice
        let generation = modelSelectionGeneration
        let previewsEnabled = Settings.shared.showTextPreview
        let vocabularyTerms = activeVocabularyTerms
        let language = scriptLanguage(for: modelChoice)
        let nativeLanguageCode = Settings.shared.selectedLanguage.nemotronLanguageCode
        let modelIsInitialized = await asrCoordinator.isInitialized(for: modelChoice)
        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        if !modelIsInitialized {
            guard !isDownloading else {
                logger.error("startRecording: selected model is still downloading")
                throw TranscriptionError.engineNotReady
            }
            logger.warning("startRecording: coordinator not initialized, preparing selected model")
            try await prepare()
        }

        let preparedModelIsInitialized = await asrCoordinator.isInitialized(for: modelChoice)
        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        guard preparedModelIsInitialized else {
            logger.error("startRecording: coordinator not initialized")
            isReady = false
            throw TranscriptionError.engineNotReady
        }
        guard audioCaptureStartupCancellation === startupCancellation,
              ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        if modelChoice == .nemotronMultilingual {
            try await prepareVocabulary(terms: vocabularyTerms, model: modelChoice, generation: generation)
        } else if modelChoice.supportsFluidAudioVocabulary {
            do { try await prepareVocabulary(terms: vocabularyTerms, model: modelChoice, generation: generation) }
            catch is CancellationError { throw CancellationError() }
            catch { logger.error("Vocabulary preparation failed: \(error.localizedDescription, privacy: .private)") }
        }
        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        try await asrCoordinator.resetSession(for: modelChoice, language: language,
                                              requiresWholeRecordingFinal: !vocabularyTerms.isEmpty,
                                              previewsEnabled: previewsEnabled)
        let signalThreshold = try await asrCoordinator.audioProcessingSignalThreshold(for: modelChoice)
        guard ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        recordingModelChoice = modelChoice
        recordingScriptLanguage = language
        recordingVocabularyTerms = vocabularyTerms
        recordingPreviewsEnabled = previewsEnabled
        lastBatchPreviewSampleCount = 0

        if modelChoice == .nemotronMultilingual {
            await asrCoordinator.setStreamingLanguage(nativeLanguageCode)
        }

        // Ensure a previous engine is fully torn down before starting a new one.
        guard audioCaptureStartupCancellation === startupCancellation,
              ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        await teardownAudioEngineIfNeeded()

        // Clear state
        guard audioCaptureStartupCancellation === startupCancellation,
              ownsSelection(modelChoice, generation: generation) else { throw CancellationError() }
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: true)
            levelSampleBuffer.reset(keepingCapacity: true)
            fullRecordingSamples.removeAll(keepingCapacity: true)
            volumeGate = AudioVolumeGate()
            retainsOriginalAudio = Self.needsOriginalAudio(model: modelChoice, vocabularyTerms: vocabularyTerms)
            totalSampleCount = 0
            droppedPendingSamples = 0
        }

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }

        let usesExplicitMicrophoneSelection = Settings.shared.selectedMicrophoneUID != nil
        let audioSessionID = UUID()
        let (audioSignals, audioSignalContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sampleLock.withLock {
            activeAudioSessionID = audioSessionID
            audioProcessingContinuation = audioSignalContinuation
            audioSignalThreshold = signalThreshold
        }

        // Start audio engine (async to avoid deadlock — the tap callback dispatches to main)
        logger.info("startRecording: dispatching to engineQueue for audio engine setup")
        let captureController: AudioCaptureController
        do {
            captureController = try await startAudioCaptureOffMainActor(
                timeout: 5, queue: engineQueue, cancellation: startupCancellation,
                onLateControllerStopped: { AudioCaptureRestartGate.shared.recordStop() }
            ) { [self] in
                try makeAudioCaptureController(
                    deviceID: deviceID,
                    usesExplicitMicrophoneSelection: usesExplicitMicrophoneSelection
                ) { [weak self] samples in
                    recoveryCapture?.append(samples)
                    guard let self else { return }
                    self.appendCapturedSamples(samples, model: modelChoice, sessionID: audioSessionID)
                }
            }
        } catch {
            // A failed microphone startup must not leave an idle SDK input
            // stream alive. Identity keeps a stale attempt from cancelling a retry.
            if audioCaptureStartupCancellation === startupCancellation {
                audioCaptureStartupCancellation = nil
                invalidateAudioProcessingSignals(sessionID: audioSessionID)
                recordingModelChoice = nil
                recordingScriptLanguage = nil
                recordingVocabularyTerms = []
                await asrCoordinator.cancelBatch()
            }
            throw error
        }

        guard audioCaptureStartupCancellation === startupCancellation,
              ownsSelection(modelChoice, generation: generation) else {
            captureController.stop()
            invalidateAudioProcessingSignals(sessionID: audioSessionID)
            AudioCaptureRestartGate.shared.recordStop()
            throw CancellationError()
        }
        audioCaptureStartupCancellation = nil

        audioCaptureController = captureController
        isRecordingActive = true
        logger.info("startRecording: audio engine set up successfully, starting transcription loop")

        // Start transcription loop
        isTranscribing = true
        transcriptionTask = Task { [weak self] in
            if modelChoice.usesTrueStreaming {
                await self?.streamingTranscriptionLoop(signals: audioSignals)
            } else {
                await self?.transcriptionLoop(signals: audioSignals)
            }
        }
    }

    #if DEBUG
    func installAudioCaptureControllerForTesting(_ controller: AudioCaptureController) {
        audioCaptureController = controller
    }
    #endif

    func stopAudioCapture() async {
        await teardownAudioEngineIfNeeded()
    }

    func stopRecording() async -> String {
        let trace = PerfTrace.begin("stt.stopToFinal")
        defer { trace.end() }
        guard isRecordingActive else { return currentTranscript }

        // Stop capture before awaiting recognition so a finishing request cannot
        // keep recording the user's microphone in the background.
        await teardownAudioEngineIfNeeded()
        let audioCounts = sampleLock.withLock {
            ["captured_samples": totalSampleCount, "dropped_pending_samples": droppedPendingSamples]
        }
        PerfTrace.event("audio.captureSummary", counts: audioCounts)
        // Stop transcription loop
        isTranscribing = false
        invalidateCurrentAudioProcessingSignals()
        if let task = transcriptionTask {
            task.cancel()
            _ = await task.result
            transcriptionTask = nil
        }

        // Final transcription
        let final_transcript = await performFinalTranscription()
        await resetAfterStop(finalTranscript: final_transcript)

        return final_transcript
    }

    func cancel() async {
        audioCaptureStartupCancellation?.cancel()
        audioCaptureStartupCancellation = nil
        isTranscribing = false
        await teardownAudioEngineIfNeeded(outcome: "cancelled")
        // stop() flushes the converter tail through the capture callback.
        // Keep the session identity valid until that callback has returned.
        invalidateCurrentAudioProcessingSignals()
        transcriptionTask?.cancel()
        let task = transcriptionTask
        await task?.value
        transcriptionTask = nil
        // Inference can suspend the batch actor. Let that iteration unwind
        // before clearing audio it may still be retiring after a successful decode.
        await asrCoordinator.cancelBatch()
        isRecordingActive = false
        firstPartialEmitted = false
        recordingModelChoice = nil
        recordingScriptLanguage = nil
        recordingVocabularyTerms = []
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: false)
            levelSampleBuffer.reset(keepingCapacity: false)
            fullRecordingSamples.removeAll(keepingCapacity: false)
            volumeGate = AudioVolumeGate()
            retainsOriginalAudio = false
            totalSampleCount = 0
        }

        await MainActor.run {
            self.currentTranscript = ""
            self.audioSamples = []
        }
    }

    /// Releases speech weights only after capture and inference owners have
    /// unwound. AppState calls this when the user selects another provider.
    func unloadDeselectedModel() async {
        modelSelectionGeneration = UUID()
        let generation = modelSelectionGeneration
        await cancel()
        guard generation == modelSelectionGeneration, Settings.shared.engineChoice != .parakeet else { return }
        await asrCoordinator.cleanup()
        guard generation == modelSelectionGeneration, Settings.shared.engineChoice != .parakeet else { return }
        loadedModels = nil
        invalidateVocabularyReadiness()
        await MainActor.run { self.isReady = false }
    }

    /// Keep the selected speech model warm while dropping vocabulary-only
    /// heads and cached graphs after FluidAudio vocabulary cleanup is deselected.
    func releaseVocabularyModels() async {
        await asrCoordinator.releaseVocabularyModels()
        invalidateVocabularyReadiness()
    }

    func transcribeRecording(at url: URL) async throws -> String {
        let trace = PerfTrace.begin("stt.transcribeFile")
        defer { trace.end() }
        let model = selectedModelChoice
        guard await asrCoordinator.isInitialized(for: model) else { throw TranscriptionError.engineNotReady }
        if model.tdtModelVersion != nil {
            // The library's disk-backed decoder keeps context across windows.
            // Independently transcribing file chunks can split and lose words.
            return try await asrCoordinator.transcribeRecording(at: url, language: scriptLanguage(for: model))
        }
        if model == .nemotronMultilingual {
            try await asrCoordinator.prepareStreamingVocabulary(terms: activeVocabularyTerms)
        }
        try await asrCoordinator.resetSession(for: model, language: scriptLanguage(for: model))
        if model == .nemotronMultilingual {
            await asrCoordinator.setStreamingLanguage(Settings.shared.selectedLanguage.nemotronLanguageCode)
        }
        if model == .senseVoice {
            let reader = try RecoveryAudioReader(url: url)
            do {
                while let samples = try reader.nextSamples(maxSamples: 16_000) {
                    try Task.checkCancellation()
                    try await asrCoordinator.appendBatchAudio(samples)
                }
                let text = try await asrCoordinator.finishBatch()
                try Task.checkCancellation()
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                await asrCoordinator.cancelBatch()
                throw error
            }
        }
        let reader = try RecoveryAudioReader(url: url)
        while let samples = try reader.nextSamples(maxSamples: Self.recoveryReadBlockSamples) {
            try Task.checkCancellation()
            // Every batch backend returned above. Native decoders retain their
            // own context while recovery feeds bounded one-second audio blocks.
            for offset in stride(from: 0, to: samples.count, by: 16_000) {
                try Task.checkCancellation()
                let buffer = try makePCMBuffer(from: Array(samples[offset..<min(offset + 16_000, samples.count)]))
                try await asrCoordinator.appendStreamingAudio(buffer)
                try await asrCoordinator.processStreamingAudio()
            }
        }
        let text = try await asrCoordinator.finishStreaming()
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transcription Loop

    /// Emits the one-shot `stt.firstPartial` event the first time a loop
    /// produces visible transcript text in the current recording session.
    private func markFirstPartialEmitted() {
        guard !firstPartialEmitted else { return }
        firstPartialEmitted = true
        PerfTrace.event("stt.firstPartial")
    }

    private func transcriptionLoop(signals: AsyncStream<Void>) async {
        for await _ in signals {
            guard isTranscribing, !Task.isCancelled else { break }
            do {
                try await processBatchAudio()
            } catch is CancellationError {
                break
            } catch {
                logger.error("Batch transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func processBatchAudio() async throws {
        let (pending, total, recent, shouldPreview) = sampleLock.withLock {
            let pending = sampleBuffer
            sampleBuffer.removeAll(keepingCapacity: true)
            let total = totalSampleCount
            let shouldPreview = BatchTranscriptionPolicy.shouldPreview(isEnabled: recordingPreviewsEnabled,
                totalSamples: total, lastPreviewSamples: lastBatchPreviewSampleCount,
                hasVisibleText: !currentTranscript.isEmpty,
                model: recordingModelChoice ?? selectedModelChoice)
            let recent = shouldPreview ? volumeGate.recentSamples : []
            return (pending, total, recent, shouldPreview)
        }
        try await asrCoordinator.appendBatchAudio(pending)
        try Task.checkCancellation()
        guard shouldPreview else { return }
        if !hasSignificantAudio(recent) {
            guard await asrCoordinator.hasRecentBatchSpeech() else { return }
        }
        try Task.checkCancellation()
        lastBatchPreviewSampleCount = total
        let text = try await asrCoordinator.batchPreview().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled else { return }
        if !text.isEmpty {
            markFirstPartialEmitted()
            currentTranscript = text
        }
    }

    #if DEBUG || PIPELINE_BENCHMARK
    func batchReplayHasSignificantAudioForTesting(_ samples: [Float]) -> Bool {
        hasSignificantAudio(samples)
    }

    func batchReplayContainsSignificantAudioForTesting(_ samples: [Float]) -> Bool {
        containsSignificantAudio(samples)
    }

    func captureSamplesForTesting(_ samples: [Float], model: ParakeetModelChoice, vocabularyTerms: [String] = []) {
        sampleLock.withLock { retainsOriginalAudio = Self.needsOriginalAudio(model: model, vocabularyTerms: vocabularyTerms) }
        appendCapturedSamples(samples, model: model)
    }

    var capturedSampleCountsForTesting: (pending: Int, retained: Int, total: Int) {
        sampleLock.withLock { (sampleBuffer.count, fullRecordingSamples.count, totalSampleCount) }
    }
    #endif

    private func streamingTranscriptionLoop(signals: AsyncStream<Void>) async {
        logger.info("streamingTranscriptionLoop: entry")
        guard await asrCoordinator.isInitialized(for: recordingModelChoice ?? selectedModelChoice) else {
            logger.error("streamingTranscriptionLoop: coordinator not initialized, exiting")
            return
        }

        for await _ in signals {
            guard isTranscribing, !Task.isCancelled else { break }

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
                let processTrace = PerfTrace.begin("stt.streamingProcess", counts: ["input_samples": pendingSamples.count])
                let text: String
                do {
                    let buffer = try makePCMBuffer(from: pendingSamples)
                    try await asrCoordinator.appendStreamingAudio(buffer)
                    try await asrCoordinator.processStreamingAudio()
                    text = await asrCoordinator.currentStreamingTranscript()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    processTrace.end(outcome: "completed")
                } catch {
                    processTrace.end(outcome: PerfTrace.outcome(for: error))
                    throw error
                }
                if !text.isEmpty {
                    markFirstPartialEmitted()
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
        let trace = PerfTrace.begin("stt.finalize")
        defer { trace.end() }
        guard await asrCoordinator.isInitialized() else { return currentTranscript }
        let liveText = currentTranscript
        if (recordingModelChoice ?? selectedModelChoice).usesTrueStreaming {
            return await finishStreamingTranscription(liveText: liveText)
        }
        let pending = sampleLock.withLock {
            let samples = sampleBuffer
            sampleBuffer.removeAll(keepingCapacity: true)
            return samples
        }
        let recorded = sampleLock.withLock { fullRecordingSamples }
        do {
            try await asrCoordinator.appendBatchAudio(pending)
            var hasSpeech = sampleLock.withLock { volumeGate.containsSignificantAudio }
            if !hasSpeech { hasSpeech = try await asrCoordinator.containsBatchSpeech() }
            guard hasSpeech else {
                await asrCoordinator.cancelBatch()
                return ""
            }
            if (recordingModelChoice ?? selectedModelChoice).supportsFluidAudioVocabulary,
               !recordingVocabularyTerms.isEmpty {
                // This opt-in full-recording pass already existed. Do not add
                // an unboosted final-window decode in front of it at Stop.
                await asrCoordinator.cancelBatch()
                let result = try await asrCoordinator.transcribeWithCustomVocabulary(recorded, terms: recordingVocabularyTerms, language: recordingScriptLanguage)
                return BatchTranscriptionPolicy.finalTranscript(result.text, fallback: liveText)
            }
            let finalText = try await asrCoordinator.finishBatch(recordedSamples: recorded)
            return BatchTranscriptionPolicy.finalTranscript(finalText, fallback: liveText)
        } catch {
            logger.error("Batch final transcription failed: \(error.localizedDescription, privacy: .public)")
            await asrCoordinator.cancelBatch()
            return liveText
        }
    }

    private func finishStreamingTranscription(liveText: String) async -> String {
        let pendingSamples = sampleLock.withLock { () -> [Float] in
            let samples = sampleBuffer
            sampleBuffer.removeAll(keepingCapacity: true)
            return samples
        }

        do {
            let finishTrace = PerfTrace.begin("stt.streamingFinish", counts: ["tail_samples": pendingSamples.count])
            defer { finishTrace.end() }
            if !pendingSamples.isEmpty {
                let buffer = try makePCMBuffer(from: pendingSamples)
                try await asrCoordinator.appendStreamingAudio(buffer)
                try await asrCoordinator.processStreamingAudio()
            }

            let finalText = try await asrCoordinator.finishStreaming()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BatchTranscriptionPolicy.finalTranscript(finalText, fallback: liveText)
        } catch {
            logger.error("Streaming final transcription failed: \(error.localizedDescription, privacy: .public)")
            return liveText
        }
    }

    private func resetAfterStop(finalTranscript: String) async {
        isRecordingActive = false
        isTranscribing = false
        firstPartialEmitted = false
        recordingModelChoice = nil
        recordingScriptLanguage = nil
        recordingVocabularyTerms = []
        sampleLock.withLock {
            sampleBuffer.removeAll(keepingCapacity: false)
            levelSampleBuffer.reset(keepingCapacity: false)
            fullRecordingSamples.removeAll(keepingCapacity: false)
            volumeGate = AudioVolumeGate()
            retainsOriginalAudio = false
            totalSampleCount = 0
        }

        await MainActor.run {
            self.currentTranscript = finalTranscript
            self.audioSamples = []
        }
    }

    private func hasSignificantAudio(_ samples: [Float]) -> Bool {
        AudioVolumeGate.qualifies(samples.suffix(AudioVolumeGate.windowSamples))
    }

    private func containsSignificantAudio(_ samples: [Float]) -> Bool {
        var gate = AudioVolumeGate()
        gate.append(samples)
        return gate.containsSignificantAudio
    }

    nonisolated private static func needsOriginalAudio(model: ParakeetModelChoice, vocabularyTerms: [String]) -> Bool {
        model.tdtModelVersion == .v2 || (model.tdtModelVersion != nil && !vocabularyTerms.isEmpty)
    }

    private func appendCapturedSamples(_ samples: [Float], model: ParakeetModelChoice, sessionID: UUID? = nil) {
        let (droppedCount, continuationToSignal) = sampleLock.withLock { () -> (Int, AsyncStream<Void>.Continuation?) in
            if let sessionID, activeAudioSessionID != sessionID { return (0, nil) }
            let dropped = max(0, sampleBuffer.count + samples.count - hardPendingSampleCap)
            droppedPendingSamples += dropped
            if dropped > 0 { sampleBuffer.removeFirst(min(dropped, sampleBuffer.count)) }
            sampleBuffer.append(contentsOf: samples.suffix(hardPendingSampleCap))
            levelSampleBuffer.append(samples)
            if !model.usesTrueStreaming {
                volumeGate.append(samples)
                if retainsOriginalAudio { fullRecordingSamples.append(contentsOf: samples) }
            }
            totalSampleCount += samples.count
            let shouldSignal = audioSignalThreshold.shouldSignal(totalSamples: totalSampleCount)
            return (dropped, shouldSignal ? audioProcessingContinuation : nil)
        }
        continuationToSignal?.yield(())
        if droppedCount > 0 {
            logger.warning("Dropped \(droppedCount, privacy: .public) buffered samples to avoid memory pressure.")
        }
    }

    private func invalidateAudioProcessingSignals(sessionID: UUID) {
        let continuation = sampleLock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard activeAudioSessionID == sessionID else { return nil }
            activeAudioSessionID = nil
            let continuation = audioProcessingContinuation
            audioProcessingContinuation = nil
            return continuation
        }
        continuation?.finish()
    }

    private func invalidateCurrentAudioProcessingSignals() {
        let sessionID = sampleLock.withLock { activeAudioSessionID }
        if let sessionID { invalidateAudioProcessingSignals(sessionID: sessionID) }
    }

    /// Concatenates disjoint SenseVoice speech segments. Repeated words are
    /// real audio and must not be removed by string overlap deduplication.
    nonisolated static func joinChunkTranscripts(base: String, addition: String) -> String {
        let lhs = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = addition.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }

        return lhs + chunkSeamSeparator(lhs: lhs, rhs: rhs) + rhs
    }

    private nonisolated static func chunkSeamSeparator(lhs: String, rhs: String) -> String {
        if lhs.hasSuffix(" ") { return "" }
        if rhs.hasPrefix(",") || rhs.hasPrefix(".") { return "" }
        if let first = rhs.unicodeScalars.first {
            // Terminal and closing punctuation belongs to the text on its left,
            // so it never takes a space before it.
            if CJKText.cjkAttachedLeadingPunctuation.contains(first.value) { return "" }
            // An opening bracket belongs to the text on its right; the space in
            // front of one depends on the left side instead.
            if CJKText.cjkOpeningPunctuation.contains(first.value) {
                return CJKText.endsWithCJK(lhs) ? "" : " "
            }
        }
        // No space between Han characters across a chunk boundary.
        if CJKText.endsWithCJK(lhs) && CJKText.startsWithCJK(rhs) { return "" }
        return " "
    }

    // MARK: - Audio Engine Lifecycle

    /// Maximum number of retired engines kept alive (prevents unbounded growth from rapid start/stop)
    private let maxRetiredEngines = 3

    private func teardownAudioEngineIfNeeded(outcome: StaticString = "completed") async {
        guard let captureController = audioCaptureController else {
            logger.info("teardownAudioEngine: no capture controller to tear down")
            return
        }
        let audioTeardownTrace = PerfTrace.begin("audio.teardown")
        defer { audioTeardownTrace.end(outcome: outcome) }
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
                AudioCaptureRestartGate.shared.recordStop()

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
    }
}

// MARK: - AsrManagerCoordinator

private actor AsrManagerCoordinator {
    private let vadModelURL: URL
    private var manager: AsrManager?
    private var models: AsrModels?
    private var streamingManager: (any StreamingAsrManager)?
    private var streamingModelChoice: ParakeetModelChoice?
    private var senseVoiceManager: SenseVoiceManager?
    private var batchVad: VadManager?
    private var batchSession: BatchTranscriptionSession?
    private var multilingualManager: StreamingNemotronMultilingualAsrManager?
    private var pendingEndOfUtterance = false
    private var ctcModels: CtcModels?
    private var cachedVocabularyHead: MLModel?
    private var preparedVocabulary: PreparedTDTVocabulary?
    private var preparedVocabularyTerms: [String] = []
    private var vocabularyPreparation: (id: UUID, terms: [String], task: Task<PreparedTDTVocabulary, Error>)?
    private var modelGeneration = UUID()
    private var lifecycleMutationInProgress = false
    private var lifecycleMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var multilingualModelDirectory: URL?
    private var preparedStreamingTerms: [String] = []
    private var streamingVocabularyPreparation: (id: UUID, terms: [String], task: Task<Void, Error>)?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AsrCoordinator"
    )

    init(vadModelURL: URL) {
        self.vadModelURL = vadModelURL
    }

    func isInitialized() -> Bool {
        guard !lifecycleMutationInProgress else { return false }
        return manager != nil || streamingManager != nil || senseVoiceManager != nil || multilingualManager != nil
    }

    func isInitialized(for modelChoice: ParakeetModelChoice) -> Bool {
        guard !lifecycleMutationInProgress else { return false }
        return isInitializedUnlocked(for: modelChoice)
    }

    private func isInitializedUnlocked(for modelChoice: ParakeetModelChoice) -> Bool {
        switch modelChoice {
        case .senseVoice:
            return senseVoiceManager != nil
        case .nemotronMultilingual:
            return multilingualManager != nil
        default:
            if let modelVersion = modelChoice.tdtModelVersion {
                return manager != nil && models?.version == modelVersion
            }
            return streamingManager != nil && streamingModelChoice == modelChoice
        }
    }

    func audioProcessingSignalThreshold(for modelChoice: ParakeetModelChoice) async throws -> AudioProcessingSignalThreshold {
        switch modelChoice {
        case .parakeetEou320:
            guard let manager = streamingManager as? StreamingEouAsrManager else {
                throw TranscriptionError.engineNotReady
            }
            let chunkSize = await manager.chunkSize
            return AudioProcessingSignalThreshold(
                firstChunkSamples: chunkSize.chunkSamples,
                subsequentChunkSamples: chunkSize.shiftSamples)
        case .nemotron560, .nemotron1120, .nemotron2240:
            guard let manager = streamingManager as? StreamingNemotronAsrManager else {
                throw TranscriptionError.engineNotReady
            }
            let config = await manager.config
            return AudioProcessingSignalThreshold(thresholdSamples: config.chunkSamples)
        case .nemotronMultilingual:
            guard let manager = multilingualManager else { throw TranscriptionError.engineNotReady }
            let config = await manager.config
            return AudioProcessingSignalThreshold(thresholdSamples: config.chunkSamples)
        default:
            guard !modelChoice.usesTrueStreaming else { throw TranscriptionError.engineNotReady }
            return AudioProcessingSignalThreshold(thresholdSamples: BatchTranscriptionPolicy.batchProcessingSignalSamples)
        }
    }

    func initializeSenseVoice(download: Bool = false) async throws {
        let trace = PerfTrace.begin("stt.modelLoad")
        defer { trace.end() }
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        await cleanupUnlocked()
        // int8: ~225 MB, ANE-targeted, accuracy-neutral per FluidAudio docs.
        // Non-ANE Macs get the fp32 encoder instead — see senseVoiceEncoderPrecision.
        let precision = ParakeetEngine.senseVoiceEncoderPrecision
        let svModels: SenseVoiceModels
        if download {
            svModels = try await SenseVoiceModels.downloadAndLoad(precision: precision)
        } else {
            let directory = fluidAudioModelCacheRoot().appendingPathComponent(Repo.senseVoiceSmall.folderName)
            svModels = try SenseVoiceModels.load(from: directory, precision: precision)
        }
        // textNorm 14 = withitn: punctuated, inverse-text-normalized output.
        // The library default (15) strips punctuation — unusable for dictation.
        let vad = try await loadSpeechDetection(download: download)
        senseVoiceManager = SenseVoiceManager(
            models: svModels,
            language: SenseVoiceConfig.defaultLanguage,
            textNorm: 14
        )
        batchVad = vad
        try await PerfTrace.measure("stt.modelWarmup") {
            _ = try await senseVoiceManager?.transcribe(audio: Self.warmupAudio)
        }
        logger.info("initializeSenseVoice: completed")
    }

    func initialize(models: AsrModels, config: ASRConfig, downloadSpeechDetection: Bool = false) async throws {
        let trace = PerfTrace.begin("stt.modelLoad")
        defer { trace.end() }
        logger.info("initialize: starting (existing manager=\(self.manager != nil, privacy: .public))")
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        await cleanupUnlocked()
        let m = AsrManager(config: config)
        try await m.loadModels(models)
        let vad = try await loadSpeechDetection(download: downloadSpeechDetection)
        manager = m
        self.models = models
        batchVad = vad
        try await PerfTrace.measure("stt.modelWarmup") {
            var state = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
            _ = try await m.transcribe(Self.warmupAudio, decoderState: &state)
        }
        logger.info("initialize: completed successfully")
    }

    func initializeStreaming(modelChoice: ParakeetModelChoice) async throws {
        let trace = PerfTrace.begin("stt.modelLoad")
        defer { trace.end() }
        guard modelChoice.usesTrueStreaming else { throw TranscriptionError.engineNotReady }
        // The picker already hides ANE-only models on Intel; this stops a stale
        // persisted selection from starting a download that can never load.
        guard modelChoice.isAvailableOnThisMac else { throw TranscriptionError.engineNotReady }
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        if isInitializedUnlocked(for: modelChoice) {
            try await resetSessionUnlocked(for: modelChoice, language: nil)
            return
        }

        await cleanupUnlocked()
        pendingEndOfUtterance = false

        switch modelChoice {
        case .parakeetEou320:
            let streaming = StreamingEouAsrManager(chunkSize: .ms320)
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
        case .nemotronMultilingual:
            let streaming = StreamingNemotronMultilingualAsrManager(configuration: nil)
            // Full-vocab variant ("auto" → multilingual/) at the 1120 ms tier:
            // one download covers every language; punctuation degrades at 560 ms.
            let variantDir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "auto",
                chunkMs: 1120,
                to: nil,
                progressHandler: nil
            )
            try await streaming.loadModels(from: variantDir)
            multilingualManager = streaming
            multilingualModelDirectory = variantDir
            streamingModelChoice = modelChoice
        case .multilingual, .multilingualUltra, .englishOnly, .compactEnglish, .senseVoice:
            // .senseVoice never reaches this switch (usesTrueStreaming is false, guarded above).
            throw TranscriptionError.engineNotReady
        }

        // Multilingual Nemotron already warms every graph in loadModels(). The
        // other native managers need a first decode as well as model loading.
        if let streamingManager {
            try await PerfTrace.measure("stt.modelWarmup") {
                let warmup = [Float](repeating: 0, count: BatchTranscriptionPolicy.sampleRate * 3)
                try await streamingManager.appendAudio(makePCMBuffer(from: warmup))
                try await streamingManager.processBufferedAudio()
                _ = try await streamingManager.finish()
                try await streamingManager.reset()
            }
        }
        pendingEndOfUtterance = false
        // Warmup must not queue an end-of-speech callback that could arrive
        // after reset and prematurely stop the first real recording.
        if let eou = streamingManager as? StreamingEouAsrManager {
            await eou.setEouCallback { [weak self] _ in
                Task { await self?.markEndOfUtteranceDetected() }
            }
        }
        logger.info("initializeStreaming: completed for \(modelChoice.displayName, privacy: .public)")
    }

    private static var warmupAudio: [Float] {
        [Float](repeating: 0, count: BatchTranscriptionPolicy.sampleRate)
    }

    private func warmVad(_ vad: VadManager) async throws {
        // Discard the warmup state: each real recording starts at .initial().
        _ = try await vad.processStreamingChunk(
            [Float](repeating: 0, count: VadManager.chunkSize), state: .initial()
        )
    }

    private func loadSpeechDetection(download: Bool) async throws -> VadManager? {
        do {
            let vad = download
                ? try await BatchSpeechDetection.download(modelsDirectory: vadModelURL.deletingLastPathComponent().deletingLastPathComponent())
                : try await BatchSpeechDetection.loadCached(at: vadModelURL)
            if let vad { try await warmVad(vad) }
            return vad
        } catch {
            try Task.checkCancellation()
            if download || error is CancellationError { throw error }
            // A damaged optional cache must not block an otherwise usable ASR
            // model, and cache-only loading must not attempt network recovery.
            logger.warning("Cached speech detection unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func downloadSpeechDetection() async throws {
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        let vad = try await loadSpeechDetection(download: true)
        try Task.checkCancellation()
        batchVad = vad
    }

    /// Serialize preparation against capture and other preparation requests.
    /// Reset clears the match tail, while the unchanged term index stays resident.
    func prepareStreamingVocabulary(terms: [String]) async throws {
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        let terms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        let generation = modelGeneration
        while let pending = streamingVocabularyPreparation {
            do { try await pending.task.value }
            catch {
                if streamingVocabularyPreparation?.id == pending.id { streamingVocabularyPreparation = nil }
                throw error
            }
            guard generation == modelGeneration else { throw CancellationError() }
            if streamingVocabularyPreparation?.id == pending.id {
                preparedStreamingTerms = pending.terms
                streamingVocabularyPreparation = nil
            }
            try Task.checkCancellation()
            guard generation == modelGeneration else { throw CancellationError() }
        }
        guard terms != preparedStreamingTerms else { return }
        guard let streaming = multilingualManager, let directory = multilingualModelDirectory else {
            throw TranscriptionError.engineNotReady
        }
        // The SDK setter cannot report failure for an argmax-only asset set.
        // Verify a logits decoder exists before advertising applied vocabulary.
        if !terms.isEmpty {
            func has(_ name: String) -> Bool {
                ["mlmodelc", "mlpackage"].contains {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).\($0)").path)
                }
            }
            guard has("decoder_joint") || has("decoder_joint_noencproj") || (has("decoder") && has("joint")) else {
                throw ASRError.processingFailed("Vocabulary requires a Nemotron logits decoder")
            }
        }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            // A lower bonus preserves unrelated speech on our goldens;
            // SDK research's 3.0/4.5 weights both over-fired on AMI.
            let weight: Float = 1
            await streaming.setCustomVocabulary(terms.map { CustomVocabularyTerm(text: $0, weight: weight) })
            try Task.checkCancellation()
            if !terms.isEmpty {
                // loadModels warms the argmax path. Exercise the logits path
                // after bias configuration, before any microphone samples.
                _ = try await streaming.process(samples: [Float](repeating: 0, count: 16_000 * 3))
                _ = try await streaming.finish()
            }
            await streaming.reset()
        }
        streamingVocabularyPreparation = (id, terms, task)
        do {
            try await task.value
            try Task.checkCancellation()
            guard generation == modelGeneration else { throw CancellationError() }
            if streamingVocabularyPreparation?.id == id {
                preparedStreamingTerms = terms
                streamingVocabularyPreparation = nil
            }
        } catch {
            if streamingVocabularyPreparation?.id == id { streamingVocabularyPreparation = nil }
            throw error
        }
    }

    func prepareVocabulary(terms: [String], progressHandler: ProgressHandler? = nil) async throws {
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        let terms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        let generation = modelGeneration
        while let pending = vocabularyPreparation {
            do {
                let prepared = try await pending.task.value
                guard generation == modelGeneration else { throw CancellationError() }
                if vocabularyPreparation?.id == pending.id {
                    preparedVocabulary = prepared
                    preparedVocabularyTerms = pending.terms
                    switch prepared {
                    case .separate(_, let loaded): ctcModels = loaded
                    case .shared(let session): cachedVocabularyHead = session.head
                    }
                    vocabularyPreparation = nil
                }
            }
            catch {
                if vocabularyPreparation?.id == pending.id { vocabularyPreparation = nil }
                throw error
            }
            if vocabularyPreparation?.id == pending.id { vocabularyPreparation = nil }
            try Task.checkCancellation()
            guard generation == modelGeneration else { throw CancellationError() }
        }
        guard !terms.isEmpty else {
            preparedVocabulary = nil
            preparedVocabularyTerms = []
            return
        }
        if preparedVocabulary != nil, preparedVocabularyTerms == terms { return }
        guard let models else { throw TranscriptionError.engineNotReady }
        let cachedCTCModels = ctcModels
        let cachedHead = cachedVocabularyHead
        let id = UUID()
        let task = Task {
            try await PerfTrace.measure("stt.vocabularyPrepare") {
                try await PreparedTDTVocabulary.prepare(models: models, terms: terms, cachedCTCModels: cachedCTCModels,
                    cachedHead: cachedHead, progressHandler: progressHandler)
            }
        }
        vocabularyPreparation = (id, terms, task)
        do {
            let prepared = try await task.value
            try Task.checkCancellation()
            guard generation == modelGeneration else { throw CancellationError() }
            if vocabularyPreparation?.id == id {
                preparedVocabulary = prepared
                preparedVocabularyTerms = terms
                switch prepared {
                case .separate(_, let loaded): ctcModels = loaded
                case .shared(let session): cachedVocabularyHead = session.head
                }
                vocabularyPreparation = nil
            }
        } catch {
            if vocabularyPreparation?.id == id { vocabularyPreparation = nil }
            throw error
        }
    }

    func resetSession(for modelChoice: ParakeetModelChoice, language: Language?, requiresWholeRecordingFinal: Bool = false,
                      previewsEnabled: Bool = true) async throws {
        await waitForLifecycleMutation()
        try Task.checkCancellation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        try await resetSessionUnlocked(
            for: modelChoice, language: language,
            requiresWholeRecordingFinal: requiresWholeRecordingFinal,
            previewsEnabled: previewsEnabled
        )
    }

    private func resetSessionUnlocked(
        for modelChoice: ParakeetModelChoice,
        language: Language?,
        requiresWholeRecordingFinal: Bool = false,
        previewsEnabled: Bool = true
    ) async throws {
        guard isInitializedUnlocked(for: modelChoice) else { throw TranscriptionError.engineNotReady }
        if !modelChoice.usesTrueStreaming {
            await cancelBatch()
            if modelChoice == .senseVoice {
                guard let senseVoiceManager else { throw TranscriptionError.engineNotReady }
                batchSession = BatchTranscriptionSession.senseVoice(manager: senseVoiceManager, vad: batchVad,
                                                                    previewsEnabled: previewsEnabled)
            } else {
                guard let manager, let models else { throw TranscriptionError.engineNotReady }
                batchSession = try await BatchTranscriptionSession.parakeet(
                    models: models, previewManager: manager, vad: batchVad, language: language,
                    requiresWholeRecordingFinal: requiresWholeRecordingFinal, previewsEnabled: previewsEnabled)
            }
            return
        }
        if modelChoice == .nemotronMultilingual {
            guard let multilingualManager, streamingModelChoice == modelChoice else {
                throw TranscriptionError.engineNotReady
            }
            pendingEndOfUtterance = false
            await multilingualManager.reset()
            return
        }
        guard let streamingManager, streamingModelChoice == modelChoice else {
            throw TranscriptionError.engineNotReady
        }
        pendingEndOfUtterance = false
        try await streamingManager.reset()
    }

    func appendBatchAudio(_ samples: [Float]) async throws {
        guard let batchSession else { throw TranscriptionError.engineNotReady }
        try await batchSession.append(samples)
    }

    func batchPreview() async throws -> String {
        guard let batchSession else { throw TranscriptionError.engineNotReady }
        return try await batchSession.preview()
    }

    func hasRecentBatchSpeech() async -> Bool {
        await batchSession?.hasRecentSpeech ?? false
    }

    func containsBatchSpeech() async throws -> Bool {
        try await batchSession?.containsSpeechIncludingTail() ?? false
    }

    func finishBatch(recordedSamples: [Float] = []) async throws -> String {
        guard let batchSession else { throw TranscriptionError.engineNotReady }
        self.batchSession = nil
        do {
            return try await batchSession.finish(recordedSamples: recordedSamples)
        } catch {
            await batchSession.cancel()
            throw error
        }
    }

    func cancelBatch() async {
        let session = batchSession
        batchSession = nil
        await session?.cancel()
    }

    private func transcribe(_ samples: [Float], language: Language?) async throws -> ASRResult {
        let trace = PerfTrace.begin("stt.transcribe", counts: ["input_samples": samples.count])
        defer { trace.end() }
        guard let manager else { throw TranscriptionError.engineNotReady }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoderState, language: language)
    }

    func transcribeRecording(at url: URL, language: Language?) async throws -> String {
        guard let manager else { throw TranscriptionError.engineNotReady }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeWithCustomVocabulary(_ samples: [Float], terms: [String], language: Language?) async throws -> ASRResult {
        let trace = PerfTrace.begin("stt.vocabularyBoost", counts: ["input_samples": samples.count, "vocabulary_terms": terms.count])
        defer { trace.end() }
        // Decode once with the same model-aware batch path used for recovery.
        // Reconstructing a second live-overlap stream loses clear v2 seam words.
        let original = try await transcribe(samples, language: language)
        let terms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !terms.isEmpty else { return original }
        do {
            // Preparation belongs before capture, never a download at Stop.
            guard preparedVocabularyTerms == terms, let preparedVocabulary else { return original }
            let text = try await PerfTrace.measure("stt.vocabularyInference") {
                try await preparedVocabulary.rescore(original, samples: samples)
            }
            try Task.checkCancellation()
            return ASRResult(text: text, confidence: original.confidence,
                             duration: original.duration, processingTime: original.processingTime)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Vocabulary rescoring failed: \(error.localizedDescription, privacy: .private)")
            return original
        }
    }

    func appendStreamingAudio(_ buffer: AVAudioPCMBuffer) async throws {
        if let multilingualManager {
            try await multilingualManager.appendAudio(buffer)
            return
        }
        guard let streamingManager else { throw TranscriptionError.engineNotReady }
        try await streamingManager.appendAudio(buffer)
    }

    func processStreamingAudio() async throws {
        if let multilingualManager {
            // process(samples: []) drains any complete chunks already appended.
            _ = try await multilingualManager.process(samples: [])
            return
        }
        guard let streamingManager else { throw TranscriptionError.engineNotReady }
        try await streamingManager.processBufferedAudio()
    }

    func currentStreamingTranscript() async -> String {
        if let multilingualManager {
            return await multilingualManager.getPartialTranscript()
        }
        guard let streamingManager else { return "" }
        return await streamingManager.getPartialTranscript()
    }

    func finishStreaming() async throws -> String {
        if let multilingualManager {
            pendingEndOfUtterance = false
            return try await multilingualManager.finish()
        }
        guard let streamingManager else { throw TranscriptionError.engineNotReady }
        pendingEndOfUtterance = false
        return try await streamingManager.finish()
    }

    func setStreamingLanguage(_ code: String?) async {
        await multilingualManager?.setLanguage(code)
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
        await waitForLifecycleMutation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        await cleanupUnlocked()
    }

    private func cleanupUnlocked() async {
        let hadInitializedManager = manager != nil || streamingManager != nil
            || senseVoiceManager != nil || multilingualManager != nil
        modelGeneration = UUID()
        let tdtTask = vocabularyPreparation?.task
        vocabularyPreparation = nil
        tdtTask?.cancel()
        _ = try? await tdtTask?.value
        preparedVocabulary = nil
        preparedVocabularyTerms = []
        cachedVocabularyHead = nil
        let vocabularyTask = streamingVocabularyPreparation?.task
        streamingVocabularyPreparation = nil
        vocabularyTask?.cancel()
        _ = try? await vocabularyTask?.value
        preparedStreamingTerms = []
        multilingualModelDirectory = nil
        await cancelBatch()
        logger.info("cleanup: releasing manager (was initialized=\(hadInitializedManager, privacy: .public))")
        if let manager {
            await manager.cleanup()
        }
        if let streamingManager {
            await streamingManager.cleanup()
        }
        if let multilingualManager {
            await multilingualManager.cleanup()
        }
        manager = nil
        models = nil
        streamingManager = nil
        streamingModelChoice = nil
        senseVoiceManager = nil
        batchVad = nil
        multilingualManager = nil
        pendingEndOfUtterance = false
        ctcModels = nil
    }

    func releaseVocabularyModels() async {
        await waitForLifecycleMutation()
        lifecycleMutationInProgress = true
        defer { finishLifecycleMutation() }
        modelGeneration = UUID()
        let tdtTask = vocabularyPreparation?.task
        vocabularyPreparation = nil
        tdtTask?.cancel()
        _ = try? await tdtTask?.value
        let streamingTask = streamingVocabularyPreparation?.task
        streamingVocabularyPreparation = nil
        streamingTask?.cancel()
        _ = try? await streamingTask?.value
        preparedVocabulary = nil
        preparedVocabularyTerms = []
        preparedStreamingTerms = []
        cachedVocabularyHead = nil
        ctcModels = nil
        if let multilingualManager {
            await multilingualManager.setCustomVocabulary([])
        }
    }

    /// Actor methods can re-enter at `await`. Keep vocabulary preparation,
    /// vocabulary release, and full cleanup from mutating shared graph state
    /// across one another's suspension points.
    private func waitForLifecycleMutation() async {
        while lifecycleMutationInProgress {
            await withCheckedContinuation { lifecycleMutationWaiters.append($0) }
        }
    }

    private func finishLifecycleMutation() {
        lifecycleMutationInProgress = false
        let waiters = lifecycleMutationWaiters
        lifecycleMutationWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}
