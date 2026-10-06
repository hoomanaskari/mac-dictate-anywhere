import SwiftUI

struct WaveformDrawing: View, Animatable {
    var level: Double
    let time: TimeInterval
    let tint: Color

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let amplitude = 0.06 + sqrt(max(0, min(1, level))) * 0.88
            for layer in 0..<2 {
                let path = WaveformGeometry.path(in: size, amplitude: amplitude, time: time, layer: layer)
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                fill.closeSubpath()
                context.fill(fill, with: .color(tint.opacity(layer == 0 ? 0.09 : 0.04)))
                context.stroke(path, with: .color(tint.opacity(layer == 0 ? 0.9 : 0.38)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
    }
}
