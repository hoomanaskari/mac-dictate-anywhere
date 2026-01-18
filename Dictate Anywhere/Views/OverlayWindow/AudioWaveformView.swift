import SwiftUI

/// Animated audio waveform visualization
struct AudioWaveformView: View {
    /// Current audio level from 0.0 to 1.0
    let audioLevel: Float

    /// Number of bars in the waveform
    private let barCount = 24

    /// Brand color for the waveform
    private let waveformColor = Color.accentColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                drawWaveform(
                    context: context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .frame(height: 32)
    }

    /// Draws the waveform bars on the canvas
    private func drawWaveform(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 3
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (size.width - totalWidth) / 2
        let minHeight: CGFloat = 4
        let maxHeight = size.height

        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + spacing)

            // Calculate height based on position and audio level
            let barHeight = calculateBarHeight(
                index: i,
                time: time,
                maxHeight: maxHeight,
                minHeight: minHeight
            )

            // Center vertically
            let y = (size.height - barHeight) / 2

            // Create rounded rectangle path
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let cornerRadius = barWidth / 2
            let path = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)

            // Calculate opacity based on position (fade at edges)
            let normalizedPosition = Double(i) / Double(barCount - 1)
            let edgeFade = 1.0 - pow(abs(normalizedPosition - 0.5) * 2, 2) * 0.3
            let opacity = 0.7 + (edgeFade * 0.3)

            // Fill with brand color
            context.fill(path, with: .color(waveformColor.opacity(opacity)))
        }
    }

    /// Calculates height for a single bar based on position, time, and audio level
    private func calculateBarHeight(index: Int, time: TimeInterval, maxHeight: CGFloat, minHeight: CGFloat) -> CGFloat {
        // Create wave pattern - center bars respond more to audio
        let normalizedPosition = Double(index) / Double(barCount - 1)
        let centerDistance = abs(normalizedPosition - 0.5) * 2  // 0 at center, 1 at edges

        // Wave animation for idle movement (smoother, slower)
        let phaseOffset = Double(index) * 0.4
        let waveValue = sin(time * 2.5 + phaseOffset)
        let idleWaveContribution = CGFloat((waveValue + 1) / 2) * 0.3

        // Audio level contribution (center bars are more sensitive)
        let audioSensitivity = 1.0 - (centerDistance * 0.5)
        let audioContribution = CGFloat(audioLevel) * audioSensitivity

        // Combine contributions (audio takes precedence when present)
        let combinedLevel = max(audioContribution, idleWaveContribution)

        // Calculate final height with smooth curve
        let availableHeight = maxHeight - minHeight
        let barHeight = minHeight + availableHeight * combinedLevel

        return barHeight
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        AudioWaveformView(audioLevel: 0.0)
            .frame(width: 200)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

        AudioWaveformView(audioLevel: 0.5)
            .frame(width: 200)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

        AudioWaveformView(audioLevel: 1.0)
            .frame(width: 200)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .padding()
    .appBackground()
}
