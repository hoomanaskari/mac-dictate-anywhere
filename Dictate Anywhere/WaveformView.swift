//
//  WaveformView.swift
//  Dictate Anywhere
//
//  Smooth multi-layer sine waveform.
//

import SwiftUI

struct WaveformView: View {
    let audioLevel: Float

    private let idleAmplitude: CGFloat = 0.12
    private var waveColor: Color {
        if #available(macOS 26, *) { return .primary }
        return .white
    }

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
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for layer in layers {
                    drawWaveLayer(context: context, size: size, time: time, layer: layer)
                }
            }
        }
        .frame(height: 24)
    }

    private func drawWaveLayer(context: GraphicsContext, size: CGSize, time: TimeInterval, layer: WaveLayer) {
        let amplitude = idleAmplitude + CGFloat(audioLevel) * (1.0 - idleAmplitude)
        let midY = size.height / 2
        let maxAmp = size.height / 2

        var fillPath = Path()
        var strokePath = Path()

        fillPath.move(to: CGPoint(x: 0, y: midY))
        strokePath.move(to: CGPoint(x: 0, y: midY))

        for x in stride(from: 0, through: size.width, by: 1) {
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
        context.stroke(strokePath, with: .color(waveColor.opacity(layer.opacity)), lineWidth: 1.5)
    }
}
