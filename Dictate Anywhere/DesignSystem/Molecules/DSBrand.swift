import SwiftUI

/// Atom: the rounded accent square holding the white app glyph.
struct DSBrandMark: View {
    /// Overall square size (36 for sidebar, 76 for About hero).
    var size: CGFloat = 36

    private var cornerRadius: CGFloat { size * 11 / 36 }
    private var glyphSize: CGFloat { size * 20 / 36 }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DS.Colors.accent)
            .frame(width: size, height: size)
            .overlay {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphSize, height: glyphSize)
                    .foregroundStyle(.white)
            }
            .shadow(color: DS.Colors.accentDeep.opacity(size > 40 ? 0.25 : 0.18), radius: size > 40 ? 20 : 4, x: 0, y: size > 40 ? 8 : 2)
    }
}

/// Molecule: sidebar brand lockup (mark + name + tagline).
struct DSBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            DSBrandMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dictate Anywhere")
                    .font(DS.Fonts.display(16))
                    .foregroundStyle(DS.Colors.ink)
                Text("On-device dictation")
                    .font(DS.Fonts.ui(11))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }
}

/// Molecule: sidebar footer card showing app status and version.
struct DSFooterCard: View {
    let statusText: String
    let statusColor: Color
    let versionText: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(statusText)
                    .font(DS.Fonts.ui(12, .medium))
                    .foregroundStyle(DS.Colors.ink)
                Text(versionText)
                    .font(DS.Fonts.ui(10.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(DS.Colors.footerCardFill, in: RoundedRectangle(cornerRadius: DS.Radius.panel))
    }
}

/// Molecule: sidebar navigation item.
struct DSNavItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textSecondary)
                    .frame(width: 17)
                Text(title)
                    .font(DS.Fonts.ui(13.5, isSelected ? .semibold : .medium))
                    .foregroundStyle(DS.Colors.ink)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(.white)
                        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
    }
}
