import SwiftUI

/// Molecule: white rounded card that hosts settings rows.
struct DSCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.bgCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
    }
}

/// Molecule: overline + card grouping (design "Section").
struct DSSection<Content: View>: View {
    let overline: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.overlineToCard) {
            DSOverline(text: overline)
            DSCard { content }
        }
    }
}

/// Molecule: page header — Fraunces title with subtitle.
struct DSSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(DS.Fonts.display(27))
                .foregroundStyle(DS.Colors.ink)
            Text(subtitle)
                .font(DS.Fonts.ui(13.5))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Template: shared scrollable page scaffold used by every screen.
struct DSPage<Content: View>: View {
    var spacing: CGFloat = DS.Spacing.section
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.top, DS.Spacing.contentTop)
            .padding(.horizontal, DS.Spacing.contentHorizontal)
            .padding(.bottom, DS.Spacing.contentBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.bgWindow)
    }
}
