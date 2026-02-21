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

    private let smoothingFactor: Float = 0.3
    private let rmsWindowSize: Int = 1600

    // MARK: - Public

    /// Updates the level from raw audio samples
    func update(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let window = Array(samples.suffix(rmsWindowSize))

        let rms = calculateRMS(window)
        smoothedLevel = smoothedLevel * smoothingFactor + rms * (1 - smoothingFactor)
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
        return min(1.0, rms * 4.0)
    }
}
