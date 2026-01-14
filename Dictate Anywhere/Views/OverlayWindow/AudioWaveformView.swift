import SwiftUI

/// Animated audio waveform visualization with bright orange bars
struct AudioWaveformView: View {
    /// Current audio level from 0.0 to 1.0
    let audioLevel: Float

    /// Number of bars in the waveform
    private let barCount = 7

    /// Bright orange color for the waveform
    private let waveformColor = Color.orange

    var body: some View {
        HStack(spacing: 8) {
            // Microphone icon
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(waveformColor)

            // Animated waveform bars using TimelineView for smooth animation
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                Canvas { context, size in
                    drawWaveform(
                        context: context,
                        size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
            .frame(width: 80, height: 28)
        }
    }

    /// Draws the waveform bars on the canvas
    private func drawWaveform(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let barWidth: CGFloat = 6
        let spacing: CGFloat = 4
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (size.width - totalWidth) / 2
        let minHeight: CGFloat = 4

        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + spacing)

            // Calculate height based on position and audio level
            let barHeight = calculateBarHeight(
                index: i,
                time: time,
                maxHeight: size.height,
                minHeight: minHeight
            )

            // Center vertically
            let y = (size.height - barHeight) / 2

            // Create rounded rectangle path
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = RoundedRectangle(cornerRadius: 3).path(in: rect)

            // Fill with orange color
            context.fill(path, with: .color(waveformColor))
        }
    }

    /// Calculates height for a single bar based on position, time, and audio level
    private func calculateBarHeight(index: Int, time: TimeInterval, maxHeight: CGFloat, minHeight: CGFloat) -> CGFloat {
        // Create wave pattern - center bars respond more to audio
        let normalizedPosition = Double(index) / Double(barCount - 1)
        let centerDistance = abs(normalizedPosition - 0.5) * 2  // 0 at center, 1 at edges

        // Wave animation for idle movement (when no/low audio)
        let phaseOffset = Double(index) * 0.6
        let waveValue = sin(time * 3.0 + phaseOffset)
        let idleWaveContribution = CGFloat((waveValue + 1) / 2) * 0.25  // Subtle idle animation

        // Audio level contribution (center bars are more sensitive)
        let audioSensitivity = 1.0 - (centerDistance * 0.4)
        let audioContribution = CGFloat(audioLevel) * audioSensitivity

        // Combine contributions (audio takes precedence when present)
        let combinedLevel = max(audioContribution, idleWaveContribution)

        // Calculate final height
        let availableHeight = maxHeight - minHeight
        let barHeight = minHeight + availableHeight * combinedLevel

        return barHeight
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // No audio
        AudioWaveformView(audioLevel: 0.0)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

        // Low audio
        AudioWaveformView(audioLevel: 0.3)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

        // Medium audio
        AudioWaveformView(audioLevel: 0.6)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

        // High audio
        AudioWaveformView(audioLevel: 1.0)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }
    .padding()
    .background(.black)
}
