//
//  WaveformView.swift
//  Dictate Anywhere
//
//  Canvas-based 24-bar animated waveform.
//

import SwiftUI

struct WaveformView: View {
    let audioLevel: Float

    private let barCount = 24
    private let waveformColor = Color.accentColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                drawWaveform(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 32)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 3
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (size.width - totalWidth) / 2
        let minHeight: CGFloat = 4
        let maxHeight = size.height

        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let barHeight = calculateBarHeight(index: i, time: time, maxHeight: maxHeight, minHeight: minHeight)
            let y = (size.height - barHeight) / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = RoundedRectangle(cornerRadius: barWidth / 2).path(in: rect)

            let normalizedPosition = Double(i) / Double(barCount - 1)
            let edgeFade = 1.0 - pow(abs(normalizedPosition - 0.5) * 2, 2) * 0.3
            let opacity = 0.7 + (edgeFade * 0.3)

            context.fill(path, with: .color(waveformColor.opacity(opacity)))
        }
    }

    private func calculateBarHeight(index: Int, time: TimeInterval, maxHeight: CGFloat, minHeight: CGFloat) -> CGFloat {
        let normalizedPosition = Double(index) / Double(barCount - 1)
        let centerDistance = abs(normalizedPosition - 0.5) * 2

        let phaseOffset = Double(index) * 0.4
        let waveValue = sin(time * 2.5 + phaseOffset)
        let idleWave = CGFloat((waveValue + 1) / 2) * 0.3

        let audioSensitivity = 1.0 - (centerDistance * 0.5)
        let audioContribution = CGFloat(audioLevel) * audioSensitivity

        let combined = max(audioContribution, idleWave)
        return minHeight + (maxHeight - minHeight) * combined
    }
}
