import SwiftUI

/// Atom: primary (accent-filled) button style.
struct DSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.ui(13, .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .shadow(color: DS.Colors.accentDeep.opacity(0.2), radius: 2, x: 0, y: 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}

/// Atom: secondary (white card) button style. `tint` colors the label
/// (pass `DS.Colors.destructive` for destructive actions).
struct DSSecondaryButtonStyle: ButtonStyle {
    var tint: Color = DS.Colors.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.ui(13, .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(DS.Colors.bgCard, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Colors.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
    static var dsDestructive: DSSecondaryButtonStyle { DSSecondaryButtonStyle(tint: DS.Colors.destructive) }
}

/// Atom: 28×28 bordered icon button (trash, etc.).
struct DSIconButton: View {
    let systemImage: String
    var tint: Color = DS.Colors.textSecondary
    var accessibilityLabel: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(DS.Colors.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.Colors.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel.isEmpty ? systemImage : accessibilityLabel)
    }
}

/// Atom: small inset "Copy"-style button with an icon and label.
struct DSInsetButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(DS.Fonts.ui(12, .medium))
            }
            .foregroundStyle(DS.Colors.ink)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(DS.Colors.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.Colors.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        }
        .buttonStyle(.plain)
    }
}

/// Atom: full-width tinted "Add another …" button.
struct DSAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(title)
                    .font(DS.Fonts.ui(13, .semibold))
            }
            .foregroundStyle(DS.Colors.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(DS.Colors.addButtonFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
    }
}
