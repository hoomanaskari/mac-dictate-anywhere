import SwiftUI

/// Molecule: single-line row — label on the left, any control on the right.
struct DSInfoRow<Trailing: View>: View {
    let label: String
    var labelColor: Color = DS.Colors.ink
    var labelWeight: Font.Weight = .medium
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(label)
                .font(DS.Fonts.ui(13.5, labelWeight))
                .foregroundStyle(labelColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, DS.Spacing.rowVertical)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}

/// Convenience: info row whose trailing content is plain secondary text.
extension DSInfoRow where Trailing == Text {
    init(label: String, value: String) {
        self.init(label: label) {
            Text(value)
                .font(DS.Fonts.ui(13.5))
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }
}

/// Molecule: row with a label + trailing control on top and a caption below.
struct DSDetailRow<Trailing: View>: View {
    let label: String
    let caption: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 24) {
                Text(label)
                    .font(DS.Fonts.ui(13.5, .medium))
                    .foregroundStyle(DS.Colors.ink)
                Spacer(minLength: 0)
                trailing
            }
            Text(caption)
                .font(DS.Fonts.ui(12.5))
                .lineSpacing(12.5 * 0.5 - 3)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}

/// Molecule: label + caption stack with a trailing toggle (design "Stacked Row").
struct DSStackedRow: View {
    let label: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(DS.Fonts.ui(13.5, .medium))
                    .foregroundStyle(DS.Colors.ink)
                Text(caption)
                    .font(DS.Fonts.ui(12.5))
                    .lineSpacing(12.5 * 0.5 - 3)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.dsSwitch)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}
