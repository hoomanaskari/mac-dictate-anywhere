//
//  TextOverlayView.swift
//  Dictate Anywhere
//
//  "Text & Overlay" page: overlay preview settings.
//

import SwiftUI

struct TextOverlayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        DSPage {
            DSSectionHeader(
                title: "Text & Overlay",
                subtitle: "The floating overlay follows you while you dictate."
            )

            DSSection(overline: "Overlay") {
                VStack(spacing: 14) {
                    DSWaveformPill()
                    Text(settings.showTextPreview
                         ? "Waveform with live text — how your overlay looks right now"
                         : "Waveform only — how your overlay looks right now")
                        .font(DS.Fonts.ui(12))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .padding(.horizontal, 24)
                .background(DS.Colors.overlayPreviewFill)
                .clipShape(
                    .rect(
                        topLeadingRadius: DS.Radius.card,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: DS.Radius.card
                    )
                )

                DSStackedRow(
                    label: "Show text preview in overlay",
                    caption: "When enabled, live transcription text appears next to the waveform.",
                    isOn: $settings.showTextPreview
                )
            }

            DSHint(text: "Keep text preview off for a calmer, distraction-free overlay.")
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
