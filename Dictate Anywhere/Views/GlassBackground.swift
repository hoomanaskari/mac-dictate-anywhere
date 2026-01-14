import SwiftUI

// MARK: - Glass Background Effect Extension

extension View {
    /// Applies a glass-like background effect using macOS 26 liquid glass when available
    @ViewBuilder
    func glassBackgroundEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect()
        } else {
            self
        }
    }
}
