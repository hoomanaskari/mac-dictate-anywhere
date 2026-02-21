//
//  AudioMonitor.swift
//  Dictate Anywhere
//
//  RMS audio level calculation for waveform visualization.
//

import Foundation
import Accelerate

@Observable
final class AudioMonitor {
    // MARK: - Properties

    var smoothedLevel: Float = 0.0

    private var lastSampleCount: Int = 0
    private let smoothingFactor: Float = 0.3

    // MARK: - Public

    /// Updates the level from raw audio samples
    func update(samples: [Float]) {
        let count = samples.count
        guard count > lastSampleCount else { return }

        // Calculate RMS of recent samples (~100ms at 16kHz = 1600 samples)
        let windowSize = min(1600, count - lastSampleCount)
        let startIndex = max(0, count - windowSize)
        let window = Array(samples[startIndex..<count])

        let rms = calculateRMS(window)
        smoothedLevel = smoothedLevel * smoothingFactor + rms * (1 - smoothingFactor)
        lastSampleCount = count
    }

    /// Resets the monitor state
    func reset() {
        smoothedLevel = 0
        lastSampleCount = 0
    }

    // MARK: - Private

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return min(1.0, rms * 4.0)
    }
}
