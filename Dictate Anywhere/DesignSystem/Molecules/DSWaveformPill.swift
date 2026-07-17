import SwiftUI

/// Molecule: static preview of the dictation overlay pill (Text & Overlay page).
/// Bar heights and active range mirror the design exactly.
struct DSWaveformPill: View {
    /// (height, isActive) for each bar, as drawn in the design.
    static let bars: [(height: CGFloat, isActive: Bool)] = [
        (8, false), (14, false), (20, false), (12, false),
        (24, true), (17, true), (10, true), (22, true), (15, true), (26, true),
        (12, false), (18, false), (9, false), (14, false),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                RoundedRectangle(cornerRadius: 2)
                    .fill(bar.isActive ? DS.Colors.accent : DS.Colors.waveformBarInactive)
                    .frame(width: 3.5, height: bar.height)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(DS.Colors.waveformPillFill, in: Capsule())
        .shadow(color: Color(hex: 0x3A2E20, opacity: 0.2), radius: 18, x: 0, y: 6)
    }
}
