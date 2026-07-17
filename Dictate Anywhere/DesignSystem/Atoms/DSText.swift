import SwiftUI

/// Atom: section overline ("STARTUP", "AUDIO", …).
struct DSOverline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.ui(12, .semibold))
            .tracking(0.4)
            .foregroundStyle(DS.Colors.textSecondary)
    }
}

/// Atom: 1pt hairline divider used inside cards.
struct DSDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSoft)
            .frame(height: 1)
    }
}

/// Atom: inline hint line with a lightbulb icon.
struct DSHint: View {
    let text: String
    var icon: String = "lightbulb"

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Atom: informational panel with tinted background (design "Panel").
struct DSPanel: View {
    let text: String
    var icon: String = "sparkles"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.accentDeep)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .lineSpacing(12.5 * 0.55 - 3)
                .foregroundStyle(DS.Colors.panelText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(DS.Colors.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.panel))
    }
}
