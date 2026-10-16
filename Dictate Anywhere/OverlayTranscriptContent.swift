import SwiftUI

/// A bounded tail anchored to the bottom avoids scrolling and centering on each token.
/// The block hugs short text; once it overflows, half of the previous line fades out above the full lines.
struct OverlayTranscriptContent: View {
    let model: OverlayModel
    let size: OverlaySize
    let textColor: Color
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOverflowing = false

    var body: some View {
        let preview = OverlayPreviewText.trimmed(model.transcript, maximumCharacters: size.characterLimit)
        OverlayTextViewport(maxHeight: size.viewportMaxHeight) {
            Text(preview.isEmpty ? "Listening…" : preview)
                .font(size.font)
                .foregroundStyle(preview.isEmpty ? OverlayPalette(scheme: colorScheme).secondaryText : textColor)
                .multilineTextAlignment(.leading)
                .lineSpacing(size.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.height > size.maxTextHeight + 1
                } action: { overflowing in
                    isOverflowing = overflowing
                }
        }
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                    .frame(height: isOverflowing ? size.overflowPeekHeight : 0)
                Color.white
            }
        }
        .accessibilityLabel(preview.isEmpty ? "Listening" : "Live transcript")
        .accessibilityValue(preview)
    }
}

/// Sizes to the text's natural height up to `maxHeight`, keeping the newest lines in view.
struct OverlayTextViewport: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let natural = text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let natural = text.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        text.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }
}
