import Foundation
import Accelerate

/// Protocol for providing audio samples to the monitor
protocol AudioSamplesProvider: AnyObject {
    func getAudioSamples() -> [Float]
}

/// Monitors audio levels from a sample provider for visualization
@Observable
final class AudioLevelMonitor {
    // MARK: - Observable Properties

    /// Current raw audio level (0.0 to 1.0)
    var currentLevel: Float = 0.0

    /// Smoothed level for visual display (reduces jitter)
    var smoothedLevel: Float = 0.0

    /// Peak level with decay (for peak indicators)
    var peakLevel: Float = 0.0

    // MARK: - Private Properties

    private var monitoringTask: Task<Void, Never>?
    private var lastSampleCount: Int = 0
    private weak var samplesProvider: AudioSamplesProvider?

    /// Smoothing factor (higher = more smoothing, range 0.0-1.0)
    private let smoothingFactor: Float = 0.3

    /// How fast peak level decays per update
    private let peakDecayRate: Float = 0.05

    /// How often to update (in milliseconds) - ~30 FPS
    private let updateInterval: UInt64 = 33

    // MARK: - Initialization

    init() {}

    // MARK: - Public Interface

    /// Starts monitoring audio levels from the given provider
    /// - Parameter provider: Object providing audio samples
    func startMonitoring(samplesProvider provider: AudioSamplesProvider) {
        // Stop any existing monitoring
        stopMonitoring()

        self.samplesProvider = provider
        lastSampleCount = 0
        currentLevel = 0
        smoothedLevel = 0
        peakLevel = 0

        // Start the monitoring loop
        monitoringTask = Task { @MainActor [weak self] in
            await self?.monitorLoop()
        }
    }

    /// Stops monitoring audio levels
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil

        // Fade out smoothly
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for _ in 0..<10 {
                self.smoothedLevel *= 0.7
                self.peakLevel *= 0.7
                try? await Task.sleep(for: .milliseconds(30))
            }
            self.smoothedLevel = 0
            self.currentLevel = 0
            self.peakLevel = 0
        }
    }

    // MARK: - Private Methods

    /// Main monitoring loop that runs at ~30 FPS
    private func monitorLoop() async {
        while !Task.isCancelled {
            updateLevel()
            try? await Task.sleep(for: .milliseconds(updateInterval))
        }
    }

    /// Updates audio level from the sample provider
    private func updateLevel() {
        guard let provider = samplesProvider else { return }

        let samples = provider.getAudioSamples()
        let currentCount = samples.count

        // Only process if we have new samples
        guard currentCount > lastSampleCount else { return }

        // Calculate RMS of recent samples
        // At 16kHz, ~100ms of audio = 1600 samples
        let windowSize = min(1600, currentCount - lastSampleCount)
        let startIndex = max(0, currentCount - windowSize)

        let newSamples = Array(samples[startIndex..<currentCount])
        let rms = calculateRMS(newSamples)

        // Update current level
        currentLevel = rms

        // Apply exponential smoothing for visual display
        smoothedLevel = smoothedLevel * smoothingFactor + rms * (1 - smoothingFactor)

        // Update peak with decay
        if rms > peakLevel {
            peakLevel = rms
        } else {
            peakLevel = max(0, peakLevel - peakDecayRate)
        }

        lastSampleCount = currentCount
    }

    /// Calculates RMS (Root Mean Square) of audio samples using Accelerate framework
    /// - Parameter samples: Array of audio samples
    /// - Returns: Normalized RMS value (0.0 to 1.0)
    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0

        // Use Accelerate for efficient RMS calculation
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        // Normalize to 0-1 range
        // Audio samples are typically -1 to 1, RMS of full-scale sine wave is ~0.707
        // Apply scaling factor for better visual representation of speech
        let normalizedLevel = min(1.0, rms * 4.0)

        return normalizedLevel
    }
}
