import SwiftUI

/// Shared, quiet hover and press feedback for the app's warm controls.
struct DSControlSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    let fill: Color
    var border: Color = DS.Colors.border
    var cornerRadius: CGFloat = DS.Radius.control
    var isPressed = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background {
                shape.fill(fill)
                    .overlay {
                        shape.fill(DS.Colors.ink.opacity(feedbackOpacity))
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? DS.Colors.textSecondary : border,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }

    private var feedbackOpacity: Double {
        guard isEnabled else { return 0 }
        return isPressed ? 0.10 : isHovered ? 0.05 : 0
    }
}
