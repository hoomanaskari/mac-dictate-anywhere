import SwiftUI

// MARK: - App Theme Colors

/// Centralized theme colors that adapt to light/dark mode
enum AppTheme {

    // MARK: - Background Colors

    /// Main window background color - adapts to system appearance
    static var windowBackground: Color {
        Color(nsColor: NSColor.windowBackgroundColor)
    }

    /// Subtle fill for containers and sections
    static var containerFill: Color {
        Color(nsColor: NSColor.controlBackgroundColor).opacity(0.5)
    }

    /// Very subtle fill for button backgrounds
    static var buttonFill: Color {
        Color.primary.opacity(0.05)
    }

    /// Progress bar track background
    static var progressTrack: Color {
        Color.primary.opacity(0.1)
    }

    // MARK: - Border Colors

    /// Standard border color for containers
    static var border: Color {
        Color.primary.opacity(0.1)
    }

    /// Subtle border for inner elements
    static var borderSubtle: Color {
        Color.primary.opacity(0.08)
    }

    /// Prominent border for key badges and buttons
    static var borderProminent: Color {
        Color.primary.opacity(0.2)
    }

    // MARK: - Text Colors

    /// Primary text - adapts automatically
    static var textPrimary: Color {
        Color.primary
    }

    /// High emphasis text (slightly less than primary)
    static var textHighEmphasis: Color {
        Color.primary.opacity(0.9)
    }

    /// Medium emphasis text for icons and labels
    static var textMediumEmphasis: Color {
        Color.primary.opacity(0.6)
    }

    /// Low emphasis text for section headers
    static var textLowEmphasis: Color {
        Color.primary.opacity(0.5)
    }

    /// Very low emphasis for subtle elements
    static var textSubtle: Color {
        Color.primary.opacity(0.4)
    }

    // MARK: - Divider

    /// Divider color
    static var divider: Color {
        Color.primary.opacity(0.1)
    }
}

// MARK: - Environment-Aware Theme Extensions

extension View {
    /// Applies the standard app background
    func appBackground() -> some View {
        self.background(AppTheme.windowBackground)
    }

    /// Applies a container background with border
    func containerBackground(cornerRadius: CGFloat = 12) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(AppTheme.containerFill)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                }
        }
    }

    /// Applies a button-style background with border
    func buttonBackground(cornerRadius: CGFloat = 10) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(AppTheme.buttonFill)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
        }
    }
}
