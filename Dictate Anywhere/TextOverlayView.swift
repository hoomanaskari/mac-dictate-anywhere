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
                OverlaySettingsPreview(settings: settings)

                OverlaySizeControl(settings: settings)
                DSDivider()
                DSDetailRow(
                    label: "Preview theme",
                    caption: "System follows your Mac, independently of the app theme."
                ) {
                    DSDropdown(
                        selection: $settings.overlayThemeMode,
                        options: ThemeMode.allCases,
                        title: \.displayName,
                        accessibilityName: "Preview theme"
                    )
                }
                DSDivider()

                DSStackedRow(
                    label: "Show text preview in overlay",
                    caption: "When enabled, live transcription text appears above the waveform.",
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

    struct Cache {
        var sizes: [CGSize]
        var width: CGFloat?
        var spacing: CGFloat?
        var size: CGSize = .zero
        var positions: [CGPoint] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        layout(proposal: proposal, cache: &cache)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        layout(proposal: proposal, cache: &cache)
        for (index, position) in cache.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, cache: inout Cache) {
        let naturalWidth = cache.sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, cache.sizes.count - 1)) * spacing
        let proposedWidth = proposal.width ?? naturalWidth
        let maxWidth = proposedWidth.isFinite ? max(0, proposedWidth) : naturalWidth
        guard cache.width != maxWidth || cache.spacing != spacing else { return }
        var positions: [CGPoint] = []
        positions.reserveCapacity(cache.sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for size in cache.sizes {
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

        cache.width = maxWidth
        cache.spacing = spacing
        cache.size = CGSize(width: maxWidth, height: totalHeight)
        cache.positions = positions
    }
}
