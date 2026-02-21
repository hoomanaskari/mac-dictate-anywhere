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

    private let attackSmoothing: Float = 0.08
    private let releaseSmoothing: Float = 0.65
    private let rmsWindowSize: Int = 800

    // MARK: - Public

    /// Updates the level from raw audio samples
    func update(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let window = Array(samples.suffix(rmsWindowSize))

        let rms = calculateRMS(window)
        let smoothing = rms > smoothedLevel ? attackSmoothing : releaseSmoothing
        smoothedLevel = smoothedLevel * smoothing + rms * (1 - smoothing)
    }

    /// Resets the monitor state
    func reset() {
        smoothedLevel = 0
    }

    // MARK: - Private

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let scaled = min(1.0, rms * 5.5)
        return powf(scaled, 0.85)
    }
}
