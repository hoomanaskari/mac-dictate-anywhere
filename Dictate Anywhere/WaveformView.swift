//
//  WaveformView.swift
//  Dictate Anywhere
//
//  Smooth multi-layer sine waveform.
//

import SwiftUI

struct WaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let audioLevel: Float

    private let idleAmplitude: CGFloat = 0.12
    @Environment(\.colorScheme) private var colorScheme
    private var waveColor: Color { OverlayPalette(scheme: colorScheme).accent }

    private struct WaveLayer {
        let frequencyMultiplier: Double
        let phaseOffset: Double
        let opacity: Double
    }

    private let layers: [WaveLayer] = [
        WaveLayer(frequencyMultiplier: 1.0, phaseOffset: 0, opacity: 0.6),
        WaveLayer(frequencyMultiplier: 1.4, phaseOffset: 1.2, opacity: 0.4),
        WaveLayer(frequencyMultiplier: 0.7, phaseOffset: 2.8, opacity: 0.25),
    ]

    var body: some View {
        Group {
            if reduceMotion {
                waveCanvas(time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    waveCanvas(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(height: OverlayMetrics.size(24))
    }

    private func waveCanvas(time: TimeInterval) -> some View {
        Canvas { context, size in
            for layer in layers {
                drawWaveLayer(context: context, size: size, time: time, layer: layer)
            }
        }
    }

    private func drawWaveLayer(context: GraphicsContext, size: CGSize, time: TimeInterval, layer: WaveLayer) {
        let amplitude = idleAmplitude + CGFloat(audioLevel) * (1.0 - idleAmplitude)
        let midY = size.height / 2
        let maxAmp = size.height / 2

        var fillPath = Path()
        var strokePath = Path()

        fillPath.move(to: CGPoint(x: 0, y: midY))
        strokePath.move(to: CGPoint(x: 0, y: midY))

        let step: CGFloat = 2
        for x in stride(from: 0, through: size.width, by: step) {
            let normalizedX = x / size.width
            let envelope = sin(.pi * normalizedX)
            let wave = sin(normalizedX * .pi * 2 * layer.frequencyMultiplier + time * 2.5 + layer.phaseOffset)
            let y = midY - wave * envelope * amplitude * maxAmp

            fillPath.addLine(to: CGPoint(x: x, y: y))
            strokePath.addLine(to: CGPoint(x: x, y: y))
        }

        fillPath.addLine(to: CGPoint(x: size.width, y: midY))
        fillPath.closeSubpath()

        context.fill(fillPath, with: .color(waveColor.opacity(layer.opacity * 0.4)))
        context.stroke(strokePath, with: .color(waveColor.opacity(layer.opacity)), lineWidth: 1)
    }
}
