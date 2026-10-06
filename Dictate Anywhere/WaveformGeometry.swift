import SwiftUI

/// Precomputed edge taper and bounded sampling avoid work proportional to width.
enum WaveformGeometry {
    private static let samples = (0...64).map { index in
        let x = Double(index) / 64
        return (x: x, envelope: sin(.pi * x))
    }

    static func path(in size: CGSize, amplitude: Double, time: TimeInterval, layer: Int) -> Path {
        guard size.width > 0, size.height > 0 else { return Path() }
        let phase = time.truncatingRemainder(dividingBy: 60) * 2.5 + Double(layer) * 1.7
        let frequency = layer == 0 ? 1.15 : 1.8
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let wave = sin(sample.x * .pi * 2 * frequency + phase)
            let point = CGPoint(
                x: sample.x * size.width,
                y: size.height / 2 - wave * sample.envelope * amplitude * size.height / 2
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
