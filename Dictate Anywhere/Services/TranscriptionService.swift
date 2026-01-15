import Foundation
import WhisperKit
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

@Observable
final class TranscriptionService {
    // MARK: - Properties

    private var whisperKit: WhisperKit?
    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private let stateManager = RecordingStateManager()

    // Observable state
    var isModelDownloaded: Bool = false
    var isModelLoaded: Bool = false
    var currentTranscript: String = ""
    var isRecording: Bool = false
    var errorMessage: String?

    // Configuration
    private(set) var modelVariant = "base"

    /// Decoding options optimized to prevent hallucinations on silence
    private var decodingOptions: DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            suppressBlank: true,                  // Suppress blank tokens
            compressionRatioThreshold: 2.4,       // Detect repetitive/nonsensical output
            logProbThreshold: -1.0,               // Filter low-confidence segments
            firstTokenLogProbThreshold: -1.5,     // Filter based on first token probability
            noSpeechThreshold: 0.6                // Detect silence - key for "thank you" prevention
        )
    }

    /// Minimum RMS audio energy required for transcription (prevents hallucinations on silence)
    private let minAudioEnergy: Float = 0.02

    /// Sets the model variant to use (e.g., "base", "small", "large-v3")
    func setModelVariant(_ variant: String) {
        modelVariant = variant
        isModelDownloaded = false
        isModelLoaded = false
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Model Management

    /// Initializes WhisperKit with the downloaded model
    func initializeWhisperKit() async throws {
        guard isModelDownloaded else {
            throw TranscriptionError.modelNotDownloaded
        }

        let config = WhisperKitConfig(
            model: modelVariant,
            verbose: false,
            prewarm: true,
            load: true
        )

        whisperKit = try await WhisperKit(config)

        await MainActor.run {
            self.isModelLoaded = true
        }
    }

    // MARK: - Recording & Transcription

    /// Starts live recording and transcription
    func startRecording(deviceID: AudioDeviceID? = nil) async {
        // Atomically check and set state to prevent multiple starts
        guard await stateManager.tryStart() else { return }

        guard let whisperKit = whisperKit else {
            errorMessage = "WhisperKit not initialized"
            await stateManager.reset()
            return
        }

        let audioProcessor = whisperKit.audioProcessor

        await MainActor.run {
            self.isRecording = true
            self.currentTranscript = ""
            self.errorMessage = nil
        }

        // Start audio capture with specified device ID
        do {
            try audioProcessor.startRecordingLive(inputDeviceID: deviceID) { _ in
                // Buffer callback - we process periodically instead
            }
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

    /// Waits until audio samples are flowing from the microphone
    /// Returns true if audio is ready, false if timeout or cancelled
    func waitForAudioReady(timeout: TimeInterval = 2.0) async -> Bool {
        guard let whisperKit = whisperKit else { return false }

        let audioProcessor = whisperKit.audioProcessor
        let startTime = Date()
        let minSamples = 160  // ~10ms of audio at 16kHz - enough to confirm mic is working

        while Date().timeIntervalSince(startTime) < timeout {
            // Check if recording was cancelled while waiting
            guard isRecording else { return false }

            if audioProcessor.audioSamples.count >= minSamples {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // Timeout - but if we have ANY samples, consider it ready
        return isRecording && audioProcessor.audioSamples.count > 0
    }

    /// Stops recording and returns the final transcript
    func stopRecording() async -> String {
        // Atomically check and set state to prevent multiple stops
        guard await stateManager.tryStop() else {
            return currentTranscript
        }

        guard let whisperKit = whisperKit else {
            await stateManager.reset()
            return currentTranscript
        }

        let audioProcessor = whisperKit.audioProcessor

        // Stop the transcription loop
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Stop audio capture
        audioProcessor.stopRecording()

        // Perform final transcription on complete audio
        let finalTranscript = await performFinalTranscription()

        await MainActor.run {
            self.isRecording = false
            self.currentTranscript = finalTranscript
        }

        // Clean up audio buffer for next session
        audioProcessor.purgeAudioSamples(keepingLast: 0)

        // Reset state to idle
        await stateManager.setIdle()

        return finalTranscript
    }

    /// Force cancels recording from any state - used when user releases Fn key during startup
    /// This bypasses normal state checks to ensure immediate cancellation
    func forceCancel() async {
        // Stop the transcription loop
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Stop audio capture if WhisperKit is available
        if let whisperKit = whisperKit {
            let audioProcessor = whisperKit.audioProcessor
            audioProcessor.stopRecording()
            audioProcessor.purgeAudioSamples(keepingLast: 0)
        }

        await MainActor.run {
            self.isRecording = false
            self.currentTranscript = ""
        }

        // Force reset state to idle regardless of current state
        await stateManager.reset()
    }

    // MARK: - Private Methods

    /// Main transcription loop that runs while recording
    private func transcriptionLoop() async {
        guard let whisperKit = whisperKit else { return }

        let audioProcessor = whisperKit.audioProcessor
        var lastSampleCount = 0

        while isTranscribing && !Task.isCancelled {
            // Wait a bit before next transcription
            try? await Task.sleep(for: .milliseconds(500))

            guard isTranscribing else { break }

            let currentSamples = audioProcessor.audioSamples
            let newSampleCount = currentSamples.count

            // Only transcribe if we have significant new audio
            // At 16kHz, 0.3 seconds = 4800 samples
            let minNewSamples = 4800
            guard newSampleCount - lastSampleCount > minNewSamples else { continue }

            let samplesArray = Array(currentSamples)

            // Check if audio has enough energy to contain speech
            // This prevents hallucinations on silence/ambient noise
            guard hasSignificantAudio(samplesArray) else {
                lastSampleCount = newSampleCount
                continue
            }

            // Perform transcription with hallucination prevention options
            do {
                let results = try await whisperKit.transcribe(
                    audioArray: samplesArray,
                    decodeOptions: decodingOptions
                )

                if let result = results.first {
                    // Additional check: skip if detected as no speech
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        await MainActor.run {
                            self.currentTranscript = text
                        }
                    }
                }
            } catch {
                // Continue on error, don't break the loop
            }

            lastSampleCount = newSampleCount
        }
    }

    /// Performs final transcription on complete audio
    private func performFinalTranscription() async -> String {
        guard let whisperKit = whisperKit else {
            return currentTranscript
        }

        let audioProcessor = whisperKit.audioProcessor
        let audioSamples = Array(audioProcessor.audioSamples)

        // Skip if too short (less than 0.5 seconds)
        guard audioSamples.count > 8000 else {
            return currentTranscript
        }

        // Skip if audio doesn't have enough energy (just silence/ambient noise)
        guard hasSignificantAudio(audioSamples) else {
            return ""  // Return empty for silent recordings
        }

        do {
            let results = try await whisperKit.transcribe(
                audioArray: audioSamples,
                decodeOptions: decodingOptions
            )

            if let result = results.first {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text
            }
            return currentTranscript
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
        whisperKit = nil
        isModelLoaded = false
    }

    /// Calculates RMS (Root Mean Square) energy of audio samples
    /// - Parameter samples: Array of audio samples
    /// - Returns: RMS energy value
    private func calculateAudioEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        return rms
    }

    /// Checks if the audio has enough energy to contain speech
    /// - Parameter samples: Audio samples to check
    /// - Returns: true if energy exceeds minimum threshold
    private func hasSignificantAudio(_ samples: [Float]) -> Bool {
        let energy = calculateAudioEnergy(samples)
        return energy > minAudioEnergy
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotDownloaded
    case initializationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The transcription model has not been downloaded yet."
        case .initializationFailed:
            return "Failed to initialize the transcription engine."
        }
    }
}

// MARK: - AudioSamplesProvider Conformance

extension TranscriptionService: AudioSamplesProvider {
    /// Returns the current audio samples from the WhisperKit audio processor
    func getAudioSamples() -> [Float] {
        guard let whisperKit = whisperKit else { return [] }
        return Array(whisperKit.audioProcessor.audioSamples)
    }
}
