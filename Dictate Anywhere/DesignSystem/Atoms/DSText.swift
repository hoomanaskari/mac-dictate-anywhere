import SwiftUI

/// Atom: section overline ("STARTUP", "AUDIO", …).
struct DSOverline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.ui(12, .semibold))
            .tracking(0.4)
            .foregroundStyle(DS.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Atom: 1pt hairline divider used inside cards.
struct DSDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSoft)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Atom: inline hint line with a lightbulb icon.
struct DSHint: View {
    let text: String
    var icon: String = "lightbulb"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accentDeep)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Shared inline progress label for setup and provider checks.
struct DSLoadingMessage: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A status or validation message beside the control or item it describes.
struct DSFieldMessage: View {
    enum Tone {
        case error
        case warning
        case success
        case info

        var icon: String {
            switch self {
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .error: return DS.Colors.destructive
            case .warning: return DS.Colors.accentDeep
            case .success: return DS.Colors.success
            case .info: return DS.Colors.textSecondary
            }
        }

        var accessibilityName: String {
            switch self {
            case .error: return "Error"
            case .warning: return "Warning"
            case .success: return "Success"
            case .info: return "Information"
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone.color)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(tone == .error ? tone.color : DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tone.accessibilityName): \(text)")
    }
}
