import SwiftUI

/// A bounded tail anchored to the bottom avoids scrolling and centering on each token.
struct OverlayTranscriptContent: View {
    let model: OverlayModel
    let size: OverlaySize
    let textColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let preview = OverlayPreviewText.trimmed(model.transcript, maximumCharacters: size.characterLimit)
        Text(preview.isEmpty ? "Listening…" : preview)
            .font(.system(size: size.fontSize, weight: .regular))
            .foregroundStyle(preview.isEmpty ? OverlayPalette(scheme: colorScheme).secondaryText : textColor)
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: size.textHeight, alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.1), .init(color: .white, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityLabel(preview.isEmpty ? "Listening" : "Live transcript")
            .accessibilityValue(preview)
    }
}
