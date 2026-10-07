import SwiftUI

/// Atom: small capsule chip ("um", "MIT License", model names, …).
/// Optionally removable (trailing ×) or tappable.
struct DSChip: View {
    @Environment(\.isEnabled) private var isEnabled
    let text: String
    var isSelected: Bool = false
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let onSelect {
                Button(action: onSelect) {
                    textLabel
                        .padding(.vertical, 4)
                        .padding(.leading, 10)
                        .padding(.trailing, onRemove == nil ? 10 : 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(text)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                textLabel
                    .padding(.vertical, 4)
                    .padding(.leading, 10)
                    .padding(.trailing, onRemove == nil ? 10 : 5)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? DS.Colors.onAccent : DS.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .background(isSelected ? AnyShapeStyle(DS.Colors.accentDeep) : AnyShapeStyle(DS.Colors.bgInset), in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : DS.Colors.border, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.5)
        .help(text)
    }

    private var textLabel: some View {
        Text(text)
            .font(DS.Fonts.ui(12, .medium))
            .foregroundStyle(isSelected ? DS.Colors.onAccent : DS.Colors.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 240, alignment: .leading)
    }
}

/// Atom: status pill with a colored dot ("Ready", "Not downloaded", …).
struct DSStatusPill: View {
    let text: String
    var dotColor: Color = DS.Colors.success
    var textColor: Color = DS.Colors.successText
    var fill: Color = DS.Colors.successSoft

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(text)
                .font(DS.Fonts.ui(12.5, .semibold))
                .foregroundStyle(textColor)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(fill, in: Capsule())
    }
}

/// Atom: keyboard keycap ("⌘", "L ⌃", …).
struct DSKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.ui(12.5, .semibold))
            .foregroundStyle(DS.Colors.ink)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(DS.Colors.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.Colors.border, lineWidth: 1))
            .shadow(color: DS.Colors.keycapShadow, radius: 0, x: 0, y: 1.5)
    }
}
