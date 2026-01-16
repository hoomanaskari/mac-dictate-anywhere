//
//  FluidTranscriptionService.swift
//  Dictate Anywhere
//
//  Streaming speech-to-text service using FluidAudio's Parakeet model.
//  Supports real-time transcription, end-of-utterance detection, and multilingual support.
//

import Foundation
import FluidAudio
import AVFoundation
import CoreAudio
import Accelerate

/// Actor to manage recording state atomically (Swift 6 compatible)
private actor RecordingStateManager {
    enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    private var state: State = .idle

    func tryStart() -> Bool {
        guard state == .idle else { return false }
        state = .starting
        return true
    }

    func setRecording() {
        state = .recording
    }

    func tryStop() -> Bool {
        guard state == .recording else { return false }
        state = .stopping
        return true
    }

    func setIdle() {
        state = .idle
    }

    func isRecording() -> Bool {
        state == .recording
    }

    func reset() {
        state = .idle
    }
}

/// Actor for thread-safe audio buffer access (Swift 6 compatible)
private actor AudioBufferActor {
    private var samples: [Float] = []

    func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    func getSamples() -> [Float] {
        return samples
    }

    func getCount() -> Int {
        return samples.count
    }

    func clear() {
        samples.removeAll()
    }
}

@Observable
final class FluidTranscriptionService {
    // MARK: - Properties

    private var asrManager: AsrManager?
    private var loadedModels: AsrModels?
    private var audioEngine: AVAudioEngine?
    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private let stateManager = RecordingStateManager()

    /// Actor for thread-safe audio buffer access
    private let audioBuffer = AudioBufferActor()

    /// Local cache for synchronous access (updated periodically)
    private var cachedSamples: [Float] = []

    // Observable state
    var isModelLoaded: Bool = false
    var currentTranscript: String = ""
    var isRecording: Bool = false
    var errorMessage: String?

    /// Selected language for transcription
    var selectedLanguage: SupportedLanguage = .english

    /// Callback triggered when end-of-utterance is detected
    var onEndOfUtterance: (() -> Void)?

    // Configuration
    /// Minimum RMS audio energy required for transcription (prevents hallucinations on silence)
    private let minAudioEnergy: Float = 0.02

    /// Transcription interval in milliseconds
    private let transcriptionIntervalMs: UInt64 = 500

    /// End-of-utterance silence threshold (seconds of silence to trigger EOU)
    private let eouSilenceThreshold: TimeInterval = 0.8

    /// Track last time we detected speech
    private var lastSpeechTime: Date?

    /// Track if we're in an EOU detection period
    private var isCheckingForEOU: Bool = false

    // MARK: - Initialization

    init() {}

    // MARK: - Model Management

    /// Initializes FluidAudio with the provided models
    func initialize(with models: AsrModels) async throws {
        self.loadedModels = models

        // Create ASR manager with default config
        asrManager = AsrManager()

        // Initialize the ASR manager with models
        try await asrManager?.initialize(models: models)

        await MainActor.run {
            self.isModelLoaded = true
        }
    }

    // MARK: - Recording & Transcription

    /// Starts live recording and transcription
    func startRecording(deviceID: AudioDeviceID? = nil) async {
        // Atomically check and set state to prevent multiple starts
        guard await stateManager.tryStart() else { return }

        guard asrManager != nil else {
            errorMessage = "FluidAudio not initialized"
            await stateManager.reset()
            return
        }

        await MainActor.run {
            self.isRecording = true
            self.currentTranscript = ""
            self.errorMessage = nil
        }

        // Clear audio buffer
        await audioBuffer.clear()
        cachedSamples = []

        // Reset EOU tracking
        lastSpeechTime = Date()
        isCheckingForEOU = false

        // Start audio capture
        do {
            try setupAndStartAudioEngine(deviceID: deviceID)
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                self.isRecording = false
            }
            await stateManager.reset()
            return
        }

        // Successfully started - update state
        await stateManager.setRecording()

        // Start transcription loop
        isTranscribing = true
        transcriptionTask = Task { [weak self] in
            await self?.transcriptionLoop()
        }
    }

    /// Sets up and starts the AVAudioEngine for recording
    private func setupAndStartAudioEngine(deviceID: AudioDeviceID?) throws {
        // Create a fresh audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode

        // Set input device if specified - MUST be done before querying formats
        if let deviceID = deviceID {
            try setInputDevice(deviceID, on: inputNode)
        }

        // Reset the engine to force it to reconfigure with the new device's format
        engine.reset()

        // Query the actual hardware format after reset
        let hardwareFormat = inputNode.inputFormat(forBus: 0)

        // Validate hardware format
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw FluidTranscriptionError.audioEngineSetupFailed
        }

        // Create a recording format using the hardware's sample rate
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw FluidTranscriptionError.audioFormatError
        }

        // Target format: 16kHz, mono, Float32 (FluidAudio requirement)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw FluidTranscriptionError.audioFormatError
        }

        // Create a converter from recording format to target format
        guard let converter = AVAudioConverter(from: recordingFormat, to: targetFormat) else {
            throw FluidTranscriptionError.audioFormatError
        }

        // Capture audioBuffer actor reference for the closure
        let buffer = self.audioBuffer

        // Install tap using the recording format
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] audioBuffer, _ in
            self?.processAudioBuffer(audioBuffer, converter: converter, targetFormat: targetFormat, buffer: buffer)
        }

        // Prepare and start the audio engine
        engine.prepare()
        try engine.start()

        // Verify engine is actually running
        guard engine.isRunning else {
            throw FluidTranscriptionError.audioEngineSetupFailed
        }
    }

    /// Sets the input device for the audio engine
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        // Skip if device ID is 0 (invalid) or kAudioObjectUnknown
        guard deviceID != 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return  // Use system default
        }

        guard let audioUnit = inputNode.audioUnit else {
            throw FluidTranscriptionError.audioEngineSetupFailed
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            throw FluidTranscriptionError.deviceSelectionFailed
        }
    }

    /// Processes incoming audio buffer (called from audio thread)
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat, buffer audioBufferActor: AudioBufferActor) {
        // Calculate frame capacity for converted buffer
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        )

        guard frameCapacity > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        // Reset converter state before each conversion to ensure clean state
        converter.reset()

        var error: NSError?
        var inputBufferConsumed = false
        let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            // Provide input buffer only once
            if inputBufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBufferConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil,
              let channelData = convertedBuffer.floatChannelData?[0],
              convertedBuffer.frameLength > 0 else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        // Add to buffer using a detached task (non-blocking from audio thread)
        Task.detached {
            await audioBufferActor.append(samples)
        }
    }

    /// Waits until audio samples are flowing from the microphone
    func waitForAudioReady(timeout: TimeInterval = 2.0) async -> Bool {
        let startTime = Date()
        let minSamples = 160  // ~10ms of audio at 16kHz

        while Date().timeIntervalSince(startTime) < timeout {
            guard isRecording else { return false }

            let sampleCount = await audioBuffer.getCount()
            if sampleCount >= minSamples {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let finalCount = await audioBuffer.getCount()
        return isRecording && finalCount > 0
    }

    /// Stops recording and returns the final transcript
    func stopRecording() async -> String {
        // Atomically check and set state to prevent multiple stops
        let canStop = await stateManager.tryStop()
        if !canStop {
            // May be in .starting or .idle state - force cleanup to ensure clean state
            await forceCancel()
            return currentTranscript
        }

        // Stop the transcription loop
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Stop audio capture
        stopAudioEngine()

        // Perform final transcription on complete audio
        let finalTranscript = await performFinalTranscription()

        await MainActor.run {
            self.isRecording = false
            self.currentTranscript = finalTranscript
        }

        // Clear audio buffer for next session
        await audioBuffer.clear()
        cachedSamples = []

        // Reset state to idle
        await stateManager.setIdle()

        return finalTranscript
    }

    /// Stops the audio engine with proper cleanup
    private func stopAudioEngine() {
        guard let engine = audioEngine else { return }

        // Remove tap first
        engine.inputNode.removeTap(onBus: 0)

        // Stop the engine
        if engine.isRunning {
            engine.stop()
        }

        // Reset to release resources
        engine.reset()

        // Clear reference
        audioEngine = nil
    }

    /// Force cancels recording from any state
    func forceCancel() async {
        // IMMEDIATELY set isRecording to false to unblock any wait loops
        await MainActor.run {
            self.isRecording = false
        }

        // Stop the transcription loop
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Stop audio capture
        stopAudioEngine()

        // Clear transcript
        await MainActor.run {
            self.currentTranscript = ""
        }

        // Clear audio buffer
        await audioBuffer.clear()
        cachedSamples = []

        // Force reset state to idle
        await stateManager.reset()
    }

    // MARK: - Private Methods

    /// Main transcription loop that runs while recording
    private func transcriptionLoop() async {
        guard let asrManager = asrManager else { return }

        var lastSampleCount = 0

        while isTranscribing && !Task.isCancelled {
            // Wait before next transcription
            try? await Task.sleep(for: .milliseconds(transcriptionIntervalMs))

            guard isTranscribing else { break }

            let currentSamples = await audioBuffer.getSamples()
            let newSampleCount = currentSamples.count

            // Update cached samples for synchronous access (visualization)
            cachedSamples = currentSamples

            // Only transcribe if we have significant new audio
            // At 16kHz, 0.3 seconds = 4800 samples
            let minNewSamples = 4800
            guard newSampleCount - lastSampleCount > minNewSamples else {
                // Check for EOU even when no new samples
                await checkEndOfUtterance(samples: currentSamples)
                continue
            }

            let samplesArray = Array(currentSamples)

            // Check if audio has enough energy to contain speech
            let hasSignificant = hasSignificantAudio(samplesArray)

            if hasSignificant {
                // Update last speech time
                lastSpeechTime = Date()
                isCheckingForEOU = false

                // Perform transcription
                do {
                    let result = try await asrManager.transcribe(samplesArray)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !text.isEmpty {
                        await MainActor.run {
                            self.currentTranscript = text
                        }
                    }
                } catch {
                    // Continue on error, don't break the loop
                }
            } else {
                // Check for end of utterance
                await checkEndOfUtterance(samples: samplesArray)
            }

            lastSampleCount = newSampleCount
        }
    }

    /// Checks if we should trigger end-of-utterance
    private func checkEndOfUtterance(samples: [Float]) async {
        guard let lastSpeech = lastSpeechTime,
              !currentTranscript.isEmpty else { return }

        let silenceDuration = Date().timeIntervalSince(lastSpeech)

        if silenceDuration >= eouSilenceThreshold && !isCheckingForEOU {
            isCheckingForEOU = true

            // Notify about end of utterance
            await MainActor.run { [weak self] in
                self?.onEndOfUtterance?()
            }
        }
    }

    /// Performs final transcription on complete audio
    private func performFinalTranscription() async -> String {
        guard let asrManager = asrManager else {
            return currentTranscript
        }

        let audioSamples = await audioBuffer.getSamples()

        // Skip if too short (less than 0.5 seconds at 16kHz = 8000 samples)
        guard audioSamples.count > 8000 else {
            return currentTranscript
        }

        // Skip final transcription if audio doesn't have enough energy
        // Fall back to live transcript instead of returning empty
        guard hasSignificantAudio(audioSamples) else {
            return currentTranscript
        }

        do {
            let result = try await asrManager.transcribe(audioSamples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? currentTranscript : text
        } catch {
            print("Final transcription error: \(error)")
            return currentTranscript
        }
    }

    /// Cleans up resources
    func cleanup() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        stopAudioEngine()
        asrManager?.cleanup()
        asrManager = nil
        loadedModels = nil
        isModelLoaded = false
    }

    /// Sets the language for transcription
    /// Note: FluidAudio Parakeet v3 is multilingual but may auto-detect language.
    /// This property is kept for future explicit language setting if the API supports it.
    func setLanguage(_ language: SupportedLanguage) {
        selectedLanguage = language
        // FluidAudio Parakeet v3 auto-detects language
        // If future versions support explicit language hints, configure here
    }

    // MARK: - Audio Analysis

    /// Calculates RMS (Root Mean Square) energy of audio samples
    private func calculateAudioEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        return rms
    }

    /// Checks if the audio has enough energy to contain speech
    private func hasSignificantAudio(_ samples: [Float]) -> Bool {
        // Only check last ~0.5 seconds for recent audio energy
        let recentSamples = samples.suffix(8000)
        let energy = calculateAudioEnergy(Array(recentSamples))
        return energy > minAudioEnergy
    }
}

// MARK: - Errors

enum FluidTranscriptionError: LocalizedError {
    case modelsNotLoaded
    case audioEngineSetupFailed
    case audioFormatError
    case deviceSelectionFailed

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "The transcription models have not been loaded yet."
        case .audioEngineSetupFailed:
            return "Failed to set up audio capture."
        case .audioFormatError:
            return "Failed to create audio format."
        case .deviceSelectionFailed:
            return "Failed to select the specified microphone."
        }
    }
}

// MARK: - AudioSamplesProvider Conformance

extension FluidTranscriptionService: AudioSamplesProvider {
    /// Returns the current audio samples for visualization (uses cached samples for sync access)
    func getAudioSamples() -> [Float] {
        return cachedSamples
    }
}
