import SwiftUI

/// Two soft ribbons respond to speech; drawing cost stays fixed at every size.
struct WaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let audioLevel: Float
    var height: CGFloat = 22
    var isActive = true

    private var level: Double {
        audioLevel.isFinite ? Double(min(1, max(0, audioLevel))) : 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isActive || level < 0.015)) { timeline in
            WaveformDrawing(
                level: level,
                time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                tint: OverlayPalette(scheme: colorScheme).accent
            )
            .animation(reduceMotion || !isActive ? nil : .easeOut(duration: 0.12), value: level)
        }
        .frame(height: height)
        // Taper the ends so the resting line reads as a voice ribbon, not a divider.
        .mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.2),
                        .init(color: .white, location: 0.8), .init(color: .clear, location: 1)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .accessibilityHidden(true)
    }
}
