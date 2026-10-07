import SwiftUI

/// Atom: primary (accent-filled) button style.
struct DSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.ui(13, .semibold))
            .foregroundStyle(DS.Colors.onAccent)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .modifier(DSControlSurface(
                fill: DS.Colors.accentDeep,
                border: DS.Colors.accentDeep,
                isPressed: configuration.isPressed
            ))
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
            .modifier(DSControlSurface(fill: DS.Colors.bgCard, isPressed: configuration.isPressed))
    }
}

/// Keeps compact actions consistent without changing their label or padding.
struct DSCompactButtonStyle: ButtonStyle {
    var fill: Color = DS.Colors.bgInset
    var cornerRadius: CGFloat = DS.Radius.small

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(DSControlSurface(
                fill: fill,
                cornerRadius: cornerRadius,
                isPressed: configuration.isPressed
            ))
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
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(DSCompactButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
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
        }
        .buttonStyle(DSCompactButtonStyle())
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
            .foregroundStyle(DS.Colors.accentDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(DSCompactButtonStyle(fill: DS.Colors.addButtonFill, cornerRadius: DS.Radius.card))
    }
}
